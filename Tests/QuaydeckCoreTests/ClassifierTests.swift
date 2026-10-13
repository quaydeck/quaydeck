import XCTest
@testable import QuaydeckCore

final class ClassifierTests: XCTestCase {

    private let classifier = Classifier(home: DevMachine.home)

    // MARK: - Dev servers

    func testRuntimeInAProjectDirectoryIsADevServer() {
        let (kind, _) = classifier.classify(command: "node",
                                            args: "node /Users/dev/code/shop/node_modules/.bin/astro dev",
                                            hasProject: true)
        XCTAssertEqual(kind, .devServer)
    }

    /// Without a project directory a runtime is just a runtime. This is what stops
    /// every Electron app that embeds node from being called a dev server.
    func testRuntimeWithoutAProjectIsNotADevServer() {
        let (kind, _) = classifier.classify(command: "node", args: "node /some/daemon.js", hasProject: false)
        XCTAssertNotEqual(kind, .devServer)
    }

    func testInstalledApplicationsAreNeverDevServers() {
        let (kind, _) = classifier.classify(
            command: "node",
            args: "/Applications/Some.app/Contents/MacOS/node --serve",
            hasProject: true)
        XCTAssertNotEqual(kind, .devServer)
    }

    func testPackageManagerInvocationsCount() {
        let (kind, _) = classifier.classify(command: "sh", args: "sh -c pnpm run dev", hasProject: true)
        XCTAssertEqual(kind, .devServer)
    }

    // MARK: - Infrastructure

    func testRecognisesInfrastructureByName() {
        XCTAssertEqual(classifier.classify(command: "postgres", args: "", hasProject: false).label, "PostgreSQL")
        XCTAssertEqual(classifier.classify(command: "mongod", args: "", hasProject: false).label, "MongoDB")
    }

    /// lsof truncates long command names, so infrastructure has to be recognisable
    /// from the argument vector too.
    func testRecognisesInfrastructureFromArgumentsWhenTheNameIsTruncated() {
        let (kind, label) = classifier.classify(
            command: "com.docke",
            args: "/Applications/Docker.app/Contents/MacOS/com.docker.backend -watchdog",
            hasProject: false)
        XCTAssertEqual(kind, .service)
        XCTAssertEqual(label, "Docker")
    }

    /// A database launched from inside a project directory is still a database.
    func testInfrastructureWinsOverDevServer() {
        let (kind, _) = classifier.classify(command: "postgres", args: "postgres -D ./data", hasProject: true)
        XCTAssertEqual(kind, .service)
    }

    // MARK: - Trust

    func testBinariesInSystemLocationsAreTrusted() {
        XCTAssertTrue(classifier.isTrusted(args: "/usr/libexec/rapportd", command: "rapportd"))
        XCTAssertTrue(classifier.isTrusted(args: "/opt/homebrew/bin/ollama serve", command: "ollama"))
        XCTAssertTrue(classifier.isTrusted(args: "/Applications/Raycast.app/x", command: "Raycast"))
    }

    func testBinariesInOddLocationsAreNot() {
        XCTAssertFalse(classifier.isTrusted(args: "/tmp/.hidden/miner --stratum", command: "miner"))
        XCTAssertFalse(classifier.isTrusted(args: "/Users/dev/Downloads/thing", command: "thing"))
    }

    /// Regression: every app running in an iOS or tvOS simulator listens from
    /// ~/Library/Developer, and used to be reported as an unrecognised listener.
    func testSimulatorApplicationsAreTrusted() {
        let path = "/Users/dev/Library/Developer/CoreSimulator/Devices/"
            + "00000000-0000-0000-0000-000000000001/data/Containers/Bundle/Application/"
            + "00000000-0000-0000-0000-000000000002/SampleTV.app/SampleTV"
        XCTAssertTrue(classifier.isTrusted(args: path, command: "SampleTV"))
        XCTAssertEqual(classifier.classify(command: "SampleTV", args: path, hasProject: false).kind, .system)
    }

    /// Version managers install runtimes under the home directory. That is normal, not
    /// suspicious.
    func testVersionManagerRuntimesAreTrusted() {
        XCTAssertTrue(classifier.isTrusted(args: "/Users/dev/.rbenv/versions/3.3.0/bin/ruby x",
                                           command: "ruby"))
        XCTAssertTrue(classifier.isTrusted(args: "/Users/dev/.nvm/versions/node/v20/bin/node x",
                                           command: "node"))
    }

    /// A relative or bare command gives us nothing to judge. Crying wolf there would
    /// train people to ignore the warning.
    func testCommandsWithNoAbsolutePathAreNotFlagged() {
        XCTAssertTrue(classifier.isTrusted(args: "", command: "somedaemon"))
    }

    // MARK: - Project-less servers

    /// An agent's preview of a chat folder has no manifest to find. It used to be filed
    /// as macOS noise and only appeared under "Show all ports".
    func testAnAgentPreviewWithoutAProjectIsAServer() {
        XCTAssertTrue(classifier.isProjectlessServer(
            command: "Python", args: "/opt/homebrew/bin/python3 -m http.server 4173",
            cwd: "/Users/dev/Documents/Codex/2026-10-08/ik-x20", startedByAgent: true))
        XCTAssertTrue(classifier.isProjectlessServer(
            command: "node", args: "/usr/local/bin/node server.js",
            cwd: "/private/tmp/claude-501/x/scratchpad", startedByAgent: true))
    }

    func testAPlainStaticServerVouchesForItself() {
        XCTAssertTrue(classifier.isProjectlessServer(
            command: "Python", args: "/usr/bin/python3 -m http.server 8000",
            cwd: "/Users/dev/Downloads/mockup", startedByAgent: false))
        XCTAssertFalse(classifier.isProjectlessServer(
            command: "node", args: "/usr/local/bin/node server.js",
            cwd: "/Users/dev/Downloads/mockup", startedByAgent: false),
            "an unattributed runtime in a folder could be any app's helper")
    }

    func testAgentToolingIsNotAServer() {
        XCTAssertFalse(classifier.isProjectlessServer(
            command: "node", args: "/usr/local/bin/node /Users/dev/.npm/_npx/1a2b/node_modules/.bin/browser-mcp --port 6006",
            cwd: "/Users/dev/Documents/Codex/2026-10-08/ik-x20", startedByAgent: true))
        XCTAssertFalse(classifier.isProjectlessServer(
            command: "node", args: "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node repl.js",
            cwd: "/Users/dev/Documents/Codex/2026-10-08/ik-x20", startedByAgent: true))
    }

    func testARuntimeInTheHomeFolderOrRootIsNotAServer() {
        XCTAssertFalse(classifier.isProjectlessServer(
            command: "node", args: "playwriter-ws-server", cwd: "/Users/dev", startedByAgent: true))
        XCTAssertFalse(classifier.isProjectlessServer(
            command: "node", args: "Raycast Backend", cwd: "/", startedByAgent: true))
    }
}
