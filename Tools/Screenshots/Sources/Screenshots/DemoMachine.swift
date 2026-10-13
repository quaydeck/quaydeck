import Foundation
import QuaydeckCore

/// A fictional Mac for screenshots: every project, chat and container is made up, so
/// nothing from a real machine ever reaches a public page.
enum DemoMachine {
    static let home = "/Users/demo"

    static let claudeSession = "5d2f1a3c-8b7e-4c19-a2d4-6f0e9b8c7a11"
    static let claudeSessionAPI = "9a8b7c6d-5e4f-4a3b-9c2d-1e0f2a3b4c5d"
    static let codexThread = "01a14c2e-77d3-7b10-9e45-3c8f1d2a6b90"

    static let listeners = """
    p101
    cnode
    n127.0.0.1:3000
    p102
    cnode
    n[::1]:5173
    p201
    cnode
    n127.0.0.1:4321
    p202
    cPython
    n127.0.0.1:8000
    p301
    cPython
    n127.0.0.1:4174
    p900
    ccom.docker.backend
    n127.0.0.1:8080
    n127.0.0.1:5432
    p50
    cControlCenter
    n*:5000
    n*:7000
    p51
    crapportd
    n*:49152
    p52
    cSpotify
    n*:57621
    """

    static let processes = """
      101     1 02:14:33  0.4 182400 /opt/homebrew/bin/node /Users/demo/code/acme-web/node_modules/.bin/next dev
      102     1    45:10  0.1  96200 /opt/homebrew/bin/node /Users/demo/code/docs/node_modules/.bin/vite
      201   210    38:02  0.3 141300 /opt/homebrew/bin/node /Users/demo/code/marketing-site/node_modules/.bin/astro dev
      210   220    38:03  0.0   2048 /bin/zsh -c npm run dev
      202   211    12:44  0.2  64100 /opt/homebrew/bin/python3 -m uvicorn app.main:app --port 8000
      211   220    12:45  0.0   2048 /bin/zsh -c uvicorn app.main:app --port 8000
      220     1 01:02:10  1.2 310000 claude
      301   310    06:31  0.0  21800 /opt/homebrew/bin/python3 -m http.server 4174 --directory /Users/demo/Documents/Codex/2026-10-14/launch/outputs
      310   320    06:32  0.0   2048 /bin/zsh -lc python3 -m http.server 4174 --directory outputs
      320     1 03:40:00  0.8 240000 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server
      900     1 1-02:00:00 1.0 900000 /Applications/Docker.app/Contents/MacOS/com.docker.backend services
       50     1 1-02:00:00 0.1  60000 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
       51     1 1-02:00:00 0.0  12000 /usr/libexec/rapportd
       52     1 03:12:00  0.6 180000 /Applications/Spotify.app/Contents/MacOS/Spotify
    """

    static let workingDirectories = """
    p101
    n/Users/demo/code/acme-web
    p102
    n/Users/demo/code/docs
    p201
    n/Users/demo/code/marketing-site
    p202
    n/Users/demo/code/api
    p301
    n/Users/demo/Documents/Codex/2026-10-14/launch
    p900
    n/
    p50
    n/
    p51
    n/
    p52
    n/
    """

    static let docker = [
        "c0ffee01\tshop-web-1\tnginx:1.27\tUp 2 hours\t127.0.0.1:8080->80/tcp\tshop\tweb\t/Users/demo/code/shop\t\t",
        "c0ffee02\tshop-db-1\tpostgres:16\tUp 2 hours (healthy)\t127.0.0.1:5432->5432/tcp\tshop\tdb\t/Users/demo/code/shop\t\t",
    ].joined(separator: "\n")

    static let fileSystem = StubFileSystem(
        directories: [
            "/Users/demo/code/acme-web", "/Users/demo/code/acme-web/.git",
            "/Users/demo/code/docs", "/Users/demo/code/docs/.git",
            "/Users/demo/code/marketing-site", "/Users/demo/code/marketing-site/.git",
            "/Users/demo/code/api", "/Users/demo/code/api/.git",
            "/Users/demo/code/shop", "/Users/demo/code/shop/.git",
            "/Users/demo/Documents/Codex/2026-10-14/launch",
            "/Users/demo/.claude/projects",
            "/Users/demo/.claude/projects/-Users-demo-code-marketing-site",
            "/Users/demo/.claude/projects/-Users-demo-code-api",
        ],
        files: [
            "/opt/homebrew/bin/git": "",
            "/usr/local/bin/docker": "",
            "/Users/demo/code/acme-web/package.json": #"{"name":"acme-web","dependencies":{"next":"15.0.0"}}"#,
            "/Users/demo/code/docs/package.json": #"{"name":"docs","devDependencies":{"vite":"6.0.0"}}"#,
            "/Users/demo/code/marketing-site/package.json": #"{"name":"marketing-site","dependencies":{"astro":"5.0.0"}}"#,
            "/Users/demo/code/api/pyproject.toml": "[project]\nname = \"api\"\n",
            "/Users/demo/.codex/session_index.jsonl":
                #"{"id":"\#(codexThread)","thread_name":"Three hero variants for the launch","updated_at":"2026-10-14T09:12:00Z"}"#,
            "/Users/demo/.claude/projects/-Users-demo-code-marketing-site/\(claudeSession).jsonl":
                #"{"type":"ai-title","aiTitle":"Redesign the pricing page","sessionId":"\#(claudeSession)"}"#
                + "\n" + #"{"type":"user","cwd":"/Users/demo/code/marketing-site","message":{}}"#,
            "/Users/demo/.claude/projects/-Users-demo-code-api/\(claudeSessionAPI).jsonl":
                #"{"type":"ai-title","aiTitle":"Rate limits for the public API","sessionId":"\#(claudeSessionAPI)"}"#,
        ]
    )

    static let environment = StubEnvironment([
        201: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": claudeSession],
        202: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": claudeSessionAPI],
        301: ["CODEX_THREAD_ID": codexThread, "CODEX_CI": "1"],
    ])

    static func inventory() -> PortInventory {
        PortInventory(
            runner: FixtureRunner([
                (exe: "lsof", fragment: "-d cwd", output: workingDirectories),
                (exe: "lsof", fragment: "-iTCP", output: listeners),
                (exe: "ps", fragment: "-Ao", output: ""),
                (exe: "ps", fragment: "-p", output: processes),
                (exe: "docker", fragment: "ps", output: docker),
                (exe: "git", fragment: "", output: "# branch.head main\n"),
            ]),
            fileSystem: fileSystem,
            environment: environment,
            signatures: StubSignatures(),
            home: home,
            readsKernel: false
        )
    }

    /// Page titles the health probe would have found.
    struct Probe: HealthProbing {
        static let titles: [Int: String] = [
            3000: "Acme · Dashboard",
            5173: "Acme Docs",
            4321: "Pricing · Acme",
            8000: "Acme API",
            4174: "Launch hero variants",
            8080: "Shop",
        ]

        func probe(port: Int) async -> HealthResult {
            guard let title = Self.titles[port] else { return .noResponse }
            return HealthResult(respondsHTTP: true, title: title, status: 200)
        }
    }
}
