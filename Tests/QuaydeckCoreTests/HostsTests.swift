import XCTest
@testable import QuaydeckCore

/// Who started each server: you, a coding agent, or Docker.
final class HostsTests: XCTestCase {

    // MARK: - Environment markers

    /// A KERN_PROCARGS2 block: argc, exec path, padding, argv, environment, then the
    /// "apple" strings the kernel appends after an empty entry.
    private func procargs(argv: [String], environment: [String]) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(argv.count), 0, 0, 0]
        bytes += Array("/usr/local/bin/node".utf8) + [0, 0, 0]
        for entry in argv + environment { bytes += Array(entry.utf8) + [0] }
        bytes += [0] + Array("ptr_munge=1".utf8) + [0]
        return bytes
    }

    func testReadsOnlyTheMarkersItAsksFor() {
        let bytes = procargs(
            argv: ["node", "server.js"],
            environment: ["PATH=/bin", "OPENAI_API_KEY=sk-secret", "CODEX_THREAD_ID=t-1",
                          "CLAUDE_CODE_MESSAGING_TOKEN=secret", "CLAUDECODE=1"]
        )
        let markers = ProcessEnvironment.parse(procargs: bytes, wanted: ProcessEnvironment.wanted)
        XCTAssertEqual(markers, ["CODEX_THREAD_ID": "t-1", "CLAUDECODE": "1"])
    }

    func testArgumentsAreNeverMistakenForEnvironment() {
        let bytes = procargs(argv: ["node", "CLAUDECODE=1"], environment: ["PATH=/bin"])
        XCTAssertTrue(ProcessEnvironment.parse(procargs: bytes, wanted: ProcessEnvironment.wanted).isEmpty)
    }

    func testTheRealReaderNeverReturnsAnUnwantedName() {
        let markers = ProcessEnvironment().markers(of: getpid())
        XCTAssertTrue(Set(markers.keys).isSubset(of: ProcessEnvironment.wanted))
        XCTAssertTrue(ProcessEnvironment().markers(of: 1).isEmpty, "launchd is never read")
    }

    // MARK: - Attribution

    private let detector = AgentDetector()

    func testTheNearestAgentInTheParentChainWins() {
        let claude = detector.attribute(environment: [:],
                                        ancestry: ["node vite", "/bin/zsh -c npm run dev", "claude --resume"])
        XCTAssertEqual(claude?.agent, .claude)

        let codex = detector.attribute(environment: [:], ancestry: [
            "node astro dev", "/bin/zsh -lc npm run dev",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server",
        ])
        XCTAssertEqual(codex?.agent, .codex)
    }

    /// The old matcher looked for "codex" anywhere in the chain, so every server in a
    /// folder called Codex was credited to it.
    func testAPathMentioningAnAgentIsNotThatAgent() {
        XCTAssertNil(detector.attribute(environment: [:], ancestry: [
            "node /Users/dev/Documents/Codex/site/node_modules/.bin/astro dev",
            "/bin/zsh -l", "login -pf dev",
        ]))
        XCTAssertNil(detector.attribute(environment: [:], ancestry: [
            "python3 /private/tmp/claude-501/scratchpad/serve.py", "/bin/zsh -l",
        ]))
    }

    func testAnAgentInstalledAsAScriptIsStillFound() {
        let found = detector.attribute(environment: [:], ancestry: [
            "node vite", "/bin/zsh -c npm run dev",
            "node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
        ])
        XCTAssertEqual(found?.agent, .claude)
    }

    /// Once the chat closes, the server is re-parented to launchd and the chain is
    /// empty. The environment still remembers.
    func testMarkersAttributeAServerWhoseAgentHasExited() {
        let codex = detector.attribute(environment: ["CODEX_THREAD_ID": "t-1"], ancestry: ["python3 -m http.server"])
        XCTAssertEqual(codex, AgentAttribution(agent: .codex, sessionID: "t-1", detached: true))

        let claude = detector.attribute(
            environment: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "s-1", "CLAUDE_CONFIG_DIR": "/Users/dev/.claude-team"],
            ancestry: ["node vite"])
        XCTAssertEqual(claude, AgentAttribution(agent: .claude, sessionID: "s-1", dataDirectory: "/Users/dev/.claude-team",
                                                detached: true))
    }

    func testTheParentChainBeatsInheritedMarkers() {
        // Codex run from inside Claude: the env carries both, the chain knows better.
        let found = detector.attribute(
            environment: ["CLAUDECODE": "1", "CODEX_THREAD_ID": "t-1", "CLAUDE_CODE_SESSION_ID": "s-1"],
            ancestry: ["node vite", "/bin/zsh -c npm run dev", "claude"])
        XCTAssertEqual(found, AgentAttribution(agent: .claude, sessionID: "s-1"))
    }

    // MARK: - Session titles

    func testUsesTheLatestCodexChatName() {
        let titles = SessionTitles(fileSystem: StubFileSystem(files: [
            "/Users/dev/.codex/session_index.jsonl": """
            {"id":"t-1","thread_name":"Maak beeldproef","updated_at":"2026-10-08T10:00:00Z"}
            {"id":"t-2","thread_name":"Other chat","updated_at":"2026-10-08T11:00:00Z"}
            {"id":"t-1","thread_name":"Beeldproef  EcoPark\\n","updated_at":"2026-10-08T12:00:00Z"}
            """,
        ]), home: DevMachine.home)
        XCTAssertEqual(titles.title(for: AgentAttribution(agent: .codex, sessionID: "t-1")), "Beeldproef EcoPark")
        XCTAssertNil(titles.title(for: AgentAttribution(agent: .codex, sessionID: "unknown")))
    }

    func testARenamedClaudeSessionKeepsItsNewName() {
        let transcript = """
        {"type":"user","message":{"content":"build the summary page"}}
        {"type":"ai-title","aiTitle":"Shop checkout","sessionId":"s-1"}
        {"type":"custom-title","customTitle":"Checkout rebuild","sessionId":"s-1"}
        {"type":"ai-title","aiTitle":"Shop checkout v2","sessionId":"s-1"}
        """
        let titles = SessionTitles(fileSystem: StubFileSystem(
            directories: ["/Users/dev/.claude-team/projects", "/Users/dev/.claude-team/projects/-Users-dev-code-shop"],
            files: ["/Users/dev/.claude-team/projects/-Users-dev-code-shop/s-1.jsonl": transcript]
        ), home: DevMachine.home)
        let attribution = AgentAttribution(agent: .claude, sessionID: "s-1", dataDirectory: "/Users/dev/.claude-team")
        XCTAssertEqual(titles.title(for: attribution), "Checkout rebuild")
    }

    // MARK: - Docker

    func testParsesPublishedPorts() {
        let pairs = DockerSource.parsePorts(
            "127.0.0.1:80->80/tcp, 0.0.0.0:8025-8026->8025-8026/tcp, :::5432->5432/tcp, "
            + "[::]:9000->9000/tcp, 9999/tcp, 0.0.0.0:53->53/udp")
        XCTAssertEqual(pairs.map(\.host), [80, 8025, 8026, 5432, 9000])
        XCTAssertEqual(pairs.map(\.container), [80, 8025, 8026, 5432, 9000])
    }

    func testControlOnlyPassesHexContainerIDs() {
        let runner = RecordingRunner()
        let control = ContainerControl(runner: runner,
                                       fileSystem: StubFileSystem(files: ["/usr/local/bin/docker": ""]),
                                       home: DevMachine.home)
        control.stop(containerID: "abc123")
        control.stop(containerID: "abc; rm -rf ~")
        control.restart(containerID: "--all")
        XCTAssertEqual(runner.calls.map(\.arguments), [["stop", "abc123"]])
    }

    // MARK: - Git

    func testReadsBranchAndDirtyStateFromOneStatusCall() {
        let clean = GitInspector.parse("# branch.oid 4b47\n# branch.head main\n# branch.upstream origin/main\n")
        XCTAssertEqual(clean, GitInspector.Status(branch: "main", dirty: false))
        let dirty = GitInspector.parse("# branch.head feat/x\n1 .M N... 100644 100644 100644 a b src/app.ts\n")
        XCTAssertEqual(dirty, GitInspector.Status(branch: "feat/x", dirty: true))
        XCTAssertEqual(GitInspector.parse("# branch.head (detached)\n"), .unknown)
        XCTAssertEqual(GitInspector.parse(""), .unknown, "not a repository")
    }

    /// Without developer tools, /usr/bin/git opens Apple's install dialog. It must never
    /// be run on such a Mac, let alone every few seconds.
    func testNeverRunsTheGitShimWithoutDeveloperTools() {
        XCTAssertNil(GitInspector.locate(fileSystem: StubFileSystem(files: ["/usr/bin/git": ""])))
        XCTAssertEqual(GitInspector.locate(fileSystem: StubFileSystem(files: [
            "/usr/bin/git": "", "/Library/Developer/CommandLineTools/usr/bin/git": "",
        ])), "/usr/bin/git")
        XCTAssertEqual(GitInspector.locate(fileSystem: StubFileSystem(files: ["/opt/homebrew/bin/git": ""])),
                       "/opt/homebrew/bin/git")

        let runner = RecordingRunner()
        let git = GitInspector(runner: runner, gitPath: nil)
        XCTAssertEqual(git.status(at: "/Users/dev/code/shop"), .unknown)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // MARK: - Kernel

    /// Opens real sockets and checks the kernel path sees them exactly as lsof would.
    func testTheKernelSeesAListeningSocketAndWhereItIsBound() throws {
        let loopback = try listeningSocket(any: false)
        defer { close(loopback.fd) }
        let everywhere = try listeningSocket(any: true)
        defer { close(everywhere.fd) }

        let mine = KernelSource().listeners().filter { $0.pid == getpid() }
        XCTAssertEqual(mine.first { $0.port == loopback.port }?.exposed, false)
        XCTAssertEqual(mine.first { $0.port == everywhere.port }?.exposed, true)
    }

    func testTheKernelDescribesAProcessLikePs() throws {
        let kernel = KernelSource()
        let me = try XCTUnwrap(kernel.process(getpid()))
        XCTAssertEqual(me.ppid, getppid())
        XCTAssertTrue(me.args.contains("xctest") || me.args.contains("Test"), me.args)
        XCTAssertGreaterThan(me.rssKB, 0)
        XCTAssertEqual(kernel.workingDirectory(of: getpid()), FileManager.default.currentDirectoryPath)
        XCTAssertEqual(KernelSource.etime(90_061), "01-01:01:01")
        XCTAssertEqual(KernelSource.etime(61), "01:01")
    }

    private func listeningSocket(any: Bool) throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = any ? INADDR_ANY : UInt32(0x7F00_0001).bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    // MARK: - Back to the session

    private func agentServer(_ agent: CodingAgent, id: String?) -> LocalServer {
        var server = LocalServer(port: 4321, pid: 42, command: "node", args: "", cwd: "/Users/dev/code/shop")
        server.kind = .devServer
        server.agent = agent
        server.agentSessionID = id
        return server
    }

    func testBuildsTheClaudeResumeCommandInTheSessionsFolder() {
        var server = agentServer(.claude, id: "67e22b1b-577d-4466-910d-9d732a445454")
        server.agentSessionDirectory = "/Users/dev/code/it's shop"
        server.agentHome = "/Users/dev/.claude-team"
        XCTAssertEqual(SessionLinks.claudeResumeCommand(for: server),
                       "cd '/Users/dev/code/it'\\''s shop' && CLAUDE_CONFIG_DIR='/Users/dev/.claude-team' "
                       + "claude --resume 67e22b1b-577d-4466-910d-9d732a445454")
    }

    /// The id comes from another process's environment and lands in a shell.
    func testRefusesAnythingButAPlainSessionID() {
        for hostile in ["abc; rm -rf ~", "$(curl evil)", "id`x`", "short", "../../etc", ""] {
            XCTAssertNil(SessionLinks.claudeResumeCommand(for: agentServer(.claude, id: hostile)), hostile)
            XCTAssertNil(SessionLinks.codexThreadURL(for: agentServer(.codex, id: hostile)), hostile)
        }
    }

    func testOpensACodexChatByItsThread() {
        let server = agentServer(.codex, id: "01a135f7-cc16-7c71-b3a5-ae9c2406c583")
        XCTAssertEqual(SessionLinks.codexThreadURL(for: server)?.absoluteString,
                       "codex://threads/01a135f7-cc16-7c71-b3a5-ae9c2406c583")
        XCTAssertEqual(SessionLinks.codexResumeCommand(for: server),
                       "codex resume 01a135f7-cc16-7c71-b3a5-ae9c2406c583")
        XCTAssertNil(SessionLinks.claudeResumeCommand(for: server))
    }

    func testReadsTheClaudeSessionFolderFromItsTranscript() {
        let transcript = Data(#"""
        {"type":"user","cwd":"/Users/dev/old","message":{}}
        {"type":"assistant","cwd":"/Users/dev/code/shop","message":{}}
        """#.utf8)
        XCTAssertEqual(SessionTitles.latestClaudeDirectory(in: transcript), "/Users/dev/code/shop")
    }

    func testKnowsWhenTheSessionThatStartedAServerHasEnded() {
        let attached = detector.attribute(environment: ["CLAUDECODE": "1"], ancestry: ["node vite", "claude"])
        XCTAssertEqual(attached?.detached, false)
        let ended = detector.attribute(environment: ["CLAUDECODE": "1"], ancestry: ["node vite"])
        XCTAssertEqual(ended?.detached, true)
    }

    func testOffersToClearServersLeftBehindByEndedSessions() {
        var old = agentServer(.codex, id: "01a135f7-cc16-7c71-b3a5-ae9c2406c583")
        old.agentDetached = true
        old.etime = "02:00:00"
        var fresh = old
        fresh = LocalServer(port: 4322, pid: 43, command: "node", args: "", cwd: "/x")
        fresh.kind = .devServer
        fresh.agent = .claude
        fresh.agentDetached = true
        fresh.etime = "05:00"
        var attached = old
        attached = LocalServer(port: 4323, pid: 44, command: "node", args: "", cwd: "/y")
        attached.kind = .devServer
        attached.agent = .claude
        attached.etime = "03:00:00"

        let advice = Advisor().build(from: Snapshot(servers: [old, fresh, attached]))
            .filter { $0.kind == .leftBehind }
        XCTAssertEqual(advice.count, 1)
        XCTAssertEqual(advice.first?.id, "leftBehind:4321", "only the one whose session ended over 30 minutes ago")
        XCTAssertTrue(advice.first?.text.contains("Codex sessions that have ended") ?? false)
    }

    // MARK: - DDEV

    func testOpensADDEVSiteAtItsOwnHostname() {
        let output = [
            "aaa111\tddev-shop-web\tddev/web\tUp 1 hour (healthy)\t127.0.0.1:58610->80/tcp, 127.0.0.1:58609->443/tcp"
                + "\tddev-shop\tweb\t/Users/dev/code/shop/.ddev\tshop\t/Users/dev/code/shop",
            "bbb222\tddev-shop-db\tddev/db\tUp 1 hour\t127.0.0.1:55003->3306/tcp"
                + "\tddev-shop\tdb\t/Users/dev/code/shop/.ddev\tshop\t/Users/dev/code/shop",
        ].joined(separator: "\n")
        let runner = FixtureRunner([(exe: "docker", fragment: "ps", output: output)])
        let docker = DockerSource(runner: runner, fileSystem: StubFileSystem(files: [
            "/usr/local/bin/docker": "",
            "/Users/dev/code/shop/.ddev/config.yaml": "name: shop\nproject_tld: test\n",
        ]), home: DevMachine.home)
        let ports = docker.publishedPorts()
        XCTAssertEqual(ports[58610]?.container.siteURL?.absoluteString, "https://shop.test")
        XCTAssertEqual(ports[58609]?.container.siteURL?.absoluteString, "https://shop.test")
        XCTAssertNil(ports[55003]?.container.siteURL, "the database container does not serve the site")
        XCTAssertEqual(ports[55003]?.container.ddevRoot, "/Users/dev/code/shop")
    }

    // MARK: - Folders

    func testNamesTheFolderAProjectlessServerServes() {
        XCTAssertEqual(PortInventory.folderName(
            servedBy: "python3 -m http.server 4174 --directory /Users/dev/Documents/Codex/2026-10-08/ik-x20/outputs",
            cwd: "/Users/dev/Documents/Codex/2026-10-08/ik-x20"), "ik-x20/outputs")
        XCTAssertEqual(PortInventory.folderName(
            servedBy: "python3 -m http.server 4332 --directory dist",
            cwd: "/Users/dev/sites/brand"), "brand/dist")
        XCTAssertEqual(PortInventory.folderName(
            servedBy: "python3 -m http.server",
            cwd: "/private/tmp/claude-501/-Users-dev/0f6e7f1c-4a1b-4c2d-9e3f-1234567890ab/scratchpad"), "scratchpad")
        XCTAssertEqual(PortInventory.folderName(
            servedBy: "node server.js", cwd: "/Users/dev/Downloads/mockup"), "mockup")
    }

    // MARK: - End to end

    private func machine() -> Snapshot {
        let listeners = """
        p100
        cnode
        n127.0.0.1:4321
        p200
        cPython
        n127.0.0.1:4173
        p300
        ccom.docker.backend
        n127.0.0.1:58610
        n127.0.0.1:58609
        n*:5432
        p400
        cnode
        n127.0.0.1:5173
        p500
        cnode
        n127.0.0.1:6006
        p600
        cagent-browser
        n127.0.0.1:60741
        p700
        cfigma_agent
        n127.0.0.1:44950
        """
        let processes = """
          100     1    01:00  0.0 102400 /usr/local/bin/node /Users/dev/code/shop/node_modules/.bin/astro dev
          200     1    05:00  0.0  20480 /opt/homebrew/Cellar/python@3.14/3.14.0/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python -m http.server 4173 --directory /Users/dev/Documents/Codex/2026-10-08/ik-x20/outputs
          300     1 1-00:00:00 2.0 900000 /Applications/Docker.app/Contents/MacOS/com.docker.backend services
          400   410    00:30  0.0  51200 /usr/local/bin/node /Users/dev/code/acme-site/node_modules/.bin/vite
          410   420    00:31  0.0   2048 /bin/zsh -c npm run dev
          420     1    02:00  1.0 300000 claude --dangerously-skip-permissions
          500     1    00:30  0.0  51200 /usr/local/bin/node /Users/dev/.npm/_npx/1a2b/node_modules/.bin/browser-mcp --port 6006
          600     1    00:10  0.0  30720 /Users/dev/.local/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64
          700     1 2-00:00:00 0.0 40960 /Users/dev/Library/Application Support/Figma/FigmaAgent.app/Contents/MacOS/figma_agent --from-desktop-app
        """
        let cwds = """
        p100
        n/Users/dev/code/shop
        p200
        n/Users/dev/Documents/Codex/2026-10-08/ik-x20
        p300
        n/
        p400
        n/Users/dev/code/acme-site
        p500
        n/Users/dev/Documents/Codex/2026-10-08/ik-x20
        p600
        n/private/tmp/claude-501/x/scratchpad
        p700
        n/
        """
        let docker = [
            "abc123\tddev-shop-web\tddev/ddev-webserver:v1\tUp 3 minutes (healthy)\t"
                + "127.0.0.1:58610->80/tcp, 127.0.0.1:58609->443/tcp\tddev-shop\tweb\t/Users/dev/code/shop/.ddev",
            "def456\tpostgres-db\tpostgres:16\tUp 2 hours\t0.0.0.0:5432->5432/tcp, :::5432->5432/tcp\t\t\t",
        ].joined(separator: "\n")

        let runner = FixtureRunner([
            (exe: "lsof", fragment: "-d cwd", output: cwds),
            (exe: "lsof", fragment: "-iTCP", output: listeners),
            (exe: "ps", fragment: "-p", output: processes),
            (exe: "docker", fragment: "ps", output: docker),
            (exe: "git", fragment: "", output: ""),
        ])
        var files = [
            "/usr/local/bin/docker": "",
            "/Users/dev/.codex/session_index.jsonl":
                #"{"id":"t-1","thread_name":"Beeldproef EcoPark","updated_at":"2026-10-08T12:00:00Z"}"#,
        ]
        for (path, contents) in [
            ("/Users/dev/code/shop/package.json", #"{"name":"shop","dependencies":{"astro":"^5.0.0"}}"#),
            ("/Users/dev/code/acme-site/package.json", #"{"name":"@acme/site","devDependencies":{"vite":"^6.0.0"}}"#),
        ] { files[path] = contents }

        let inventory = PortInventory(
            runner: runner,
            fileSystem: StubFileSystem(directories: ["/Users/dev/code/shop", "/Users/dev/code/shop/.ddev",
                                                     "/Users/dev/code/acme-site"],
                                       files: files),
            environment: StubEnvironment([
                200: ["CODEX_THREAD_ID": "t-1"],
                500: ["CODEX_THREAD_ID": "t-1"],
                600: ["CLAUDECODE": "1"],
            ]),
            signatures: StubSignatures([700: "Figma, Inc."]),
            home: DevMachine.home
        )
        return inventory.snapshot(includeBusyProcesses: false)
    }

    private func server(_ port: Int, in snapshot: Snapshot) throws -> LocalServer {
        try XCTUnwrap(snapshot.servers.first { $0.port == port }, "no server on :\(port)")
    }

    func testGroupsDevServersByWhoStartedThem() throws {
        let snapshot = machine()
        XCTAssertEqual(snapshot.devServerGroups.map(\.id), ["you", "claude", "codex"])
        XCTAssertNil(try server(4321, in: snapshot).agent)
        XCTAssertEqual(try server(5173, in: snapshot).agent, .claude)
    }

    /// The case that used to hide: a Codex preview of a chat's outputs folder.
    func testACodexPreviewShowsAsACodexServerWithItsChat() throws {
        let preview = try server(4173, in: machine())
        XCTAssertEqual(preview.kind, .devServer)
        XCTAssertEqual(preview.agent, .codex)
        XCTAssertEqual(preview.agentSession, "Beeldproef EcoPark")
        XCTAssertEqual(preview.headline, "ik-x20/outputs · Python")
        XCTAssertNil(preview.projectPath, "a chat folder is not a project to pin or restart")
    }

    func testAnAgentsOwnToolingStaysOutOfTheServerList() throws {
        let snapshot = machine()
        XCTAssertFalse(try server(6006, in: snapshot).isDevServer)
        XCTAssertEqual(snapshot.otherServers.map(\.port), [60741, 6006, 44950])
    }

    /// Markers explain an alert but never silence one: anything can set them.
    func testAnAgentsUnrecognisedToolStillAlertsAndSaysWhoStartedIt() throws {
        let snapshot = machine()
        let tool = try server(60741, in: snapshot)
        XCTAssertEqual(tool.kind, .unrecognised)
        XCTAssertEqual(tool.agent, .claude)
        let advice = try XCTUnwrap(Advisor().build(from: snapshot).first { $0.port == 60741 })
        XCTAssertEqual(advice.kind, .unrecognised)
        XCTAssertTrue(advice.text.hasSuffix("Started by Claude."))
    }

    func testPublishedPortsBecomeContainersNotDockerNoise() throws {
        let snapshot = machine()
        XCTAssertEqual(snapshot.containers.count, 2)

        let web = try XCTUnwrap(snapshot.containers.first { $0.container.name == "ddev-shop-web" })
        XCTAssertEqual(web.title, "shop", "named after the project its compose file lives in")
        XCTAssertEqual(web.service, "web")
        XCTAssertEqual(web.ports.map(\.port), [58609, 58610])
        XCTAssertEqual(web.primary.port, 58610, "port 80 inside, so a click opens the site")
        XCTAssertEqual(web.portsText, ":58609→443  :58610→80")
        XCTAssertEqual(web.projectPath, "/Users/dev/code/shop")

        let database = try server(5432, in: snapshot)
        XCTAssertEqual(database.kind, .container)
        XCTAssertTrue(database.exposed)
        XCTAssertFalse(database.probeable, "a database port is never sent an HTTP request")
    }

    /// The pid holding a container port is Docker's proxy: its numbers are not the
    /// container's, and quitting it would stop every container at once.
    func testContainerRowsDoNotCarryTheProxysStats() throws {
        let web = try server(58610, in: machine())
        XCTAssertEqual(web.memMB, 0)
        XCTAssertEqual(web.cpu, 0)
        XCTAssertNil(web.uptimeSeconds)
        XCTAssertTrue(Advisor().build(from: machine()).allSatisfy { $0.kind != .memoryHog })
    }

    // MARK: - Signatures

    /// Figma's font helper runs from the home folder all day. Its Developer ID
    /// signature, not its location, decides that it is fine.
    func testASignedHelperInAnOddPlaceIsNotAnAlert() throws {
        let snapshot = machine()
        let figma = try server(44950, in: snapshot)
        XCTAssertEqual(figma.kind, .system)
        XCTAssertEqual(figma.systemLabel, "Figma font helper")
        XCTAssertFalse(Advisor().build(from: snapshot).contains { $0.port == 44950 })
        XCTAssertEqual(try server(60741, in: snapshot).kind, .unrecognised, "ad-hoc signed tools still alert")
    }

    func testReadsTheOrganisationFromASigningCertificate() {
        XCTAssertEqual(CodeSignatureChecker.organisation(fromSubject: "Developer ID Application: Figma, Inc. (T8RA8NE3B7)"),
                       "Figma, Inc.")
        XCTAssertEqual(CodeSignatureChecker.organisation(fromSubject: "Software Signing"), "Apple")
    }

    /// Runs /bin/sleep as it ships (Apple-signed) and as an ad-hoc re-signed copy.
    func testChecksTheSignatureOfARunningProcess() throws {
        let checker = CodeSignatureChecker()

        let apple = try running("/bin/sleep")
        defer { apple.terminate() }
        XCTAssertEqual(checker.trustedSigner(of: apple.processIdentifier), "Apple")

        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("quaydeck-adhoc-\(UUID().uuidString)").path
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: copy)
        defer { try? FileManager.default.removeItem(atPath: copy) }
        _ = ShellRunner().run("/usr/bin/codesign", ["--force", "--sign", "-", copy])
        let adhoc = try running(copy)
        defer { adhoc.terminate() }
        XCTAssertNil(checker.trustedSigner(of: adhoc.processIdentifier))

        XCTAssertNil(checker.trustedSigner(of: 1), "launchd is never examined")
    }

    private func running(_ path: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["30"]
        try process.run()
        return process
    }

    func testWarnsAboutAContainerOnEveryInterface() {
        let advice = Advisor().build(from: machine())
        XCTAssertTrue(advice.contains { $0.kind == .exposed && $0.port == 5432 })
        XCTAssertFalse(advice.contains { $0.kind == .exposed && $0.port == 58610 })
    }

    func testDockerIsOnlyAskedWhenItsProxyHoldsAPort() {
        let runner = RecordingRunner(outputs: [
            "lsof": "p100\ncnode\nn127.0.0.1:4321\n",
        ])
        let inventory = PortInventory(runner: runner,
                                      fileSystem: StubFileSystem(files: ["/usr/local/bin/docker": ""]),
                                      environment: StubEnvironment(), signatures: StubSignatures(),
                                      home: DevMachine.home)
        _ = inventory.snapshot(includeBusyProcesses: false)
        XCTAssertFalse(runner.calls.contains { $0.executable.hasSuffix("docker") })
    }
}

/// Records every command and answers by executable suffix.
final class RecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(executable: String, arguments: [String])] = []
    private let outputs: [String: String]

    init(outputs: [String: String] = [:]) {
        self.outputs = outputs
    }

    var calls: [(executable: String, arguments: [String])] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func run(_ executable: String, _ arguments: [String]) -> String {
        lock.lock(); _calls.append((executable, arguments)); lock.unlock()
        return outputs.first { executable.hasSuffix($0.key) }?.value ?? ""
    }
}
