import XCTest
@testable import QuaydeckCore

/// End-to-end: recorded `lsof` and `ps` output in, a finished snapshot out.
final class PortInventoryTests: XCTestCase {

    private func snapshot() throws -> Snapshot {
        let inventory = DevMachine.inventory(
            listeners: try Fixture.text("lsof-dev.txt"),
            processes: try Fixture.text("ps-dev.txt"),
            cwds: try Fixture.text("lsof-cwd-dev.txt")
        )
        return inventory.snapshot(includeBusyProcesses: false)
    }

    private func server(_ port: Int, in snapshot: Snapshot) throws -> LocalServer {
        try XCTUnwrap(snapshot.servers.first { $0.port == port }, "no server on :\(port)")
    }

    // MARK: - Collapsing

    /// A server bound to both IPv4 and IPv6 is two lsof rows and one server.
    func testCollapsesDualStackBindingsIntoOneRow() throws {
        let result = try snapshot()
        XCTAssertEqual(result.servers.filter { $0.port == 4321 }.count, 1)
    }

    func testFindsEveryDistinctPort() throws {
        let ports = Set(try snapshot().servers.map(\.port))
        XCTAssertEqual(ports, [5173, 4321, 4322, 8000, 5432, 6379, 31337, 3000, 2375])
    }

    // MARK: - Resolution

    func testResolvesProjectAndFrameworkForADevServer() throws {
        let vite = try server(5173, in: try snapshot())
        XCTAssertEqual(vite.kind, .devServer)
        XCTAssertEqual(vite.project, "site")
        XCTAssertEqual(vite.framework, "Vite")
        XCTAssertEqual(vite.projectPath, "/Users/dev/code/acme-site")
        XCTAssertEqual(vite.memMB, 180)
    }

    func testResolvesARubyProjectWithoutAPackageManifest() throws {
        let rails = try server(3000, in: try snapshot())
        XCTAssertEqual(rails.kind, .devServer)
        XCTAssertEqual(rails.project, "rails-app")
        XCTAssertEqual(rails.framework, "Rails")
    }

    func testResolvesAPythonServerFromItsWorkingDirectory() throws {
        let python = try server(8000, in: try snapshot())
        XCTAssertEqual(python.kind, .devServer)
        XCTAssertEqual(python.project, "notes")
        XCTAssertEqual(python.framework, "Python")
    }

    // MARK: - Classification

    func testLabelsInfrastructure() throws {
        let result = try snapshot()
        XCTAssertEqual(try server(5432, in: result).systemLabel, "PostgreSQL")
        XCTAssertEqual(try server(6379, in: result).systemLabel, "Redis")
        XCTAssertEqual(try server(2375, in: result).systemLabel, "Docker")
        XCTAssertTrue(try server(5432, in: result).isService)
    }

    func testFlagsAListenerFromAnUntrustedPath() throws {
        let miner = try server(31337, in: try snapshot())
        XCTAssertEqual(miner.kind, .unrecognised)
        XCTAssertTrue(miner.exposed)
        XCTAssertTrue(miner.suspicious, "untrusted and network-reachable is the combination that matters")
    }

    func testNoDevServerIsMisreadAsSuspicious() throws {
        let result = try snapshot()
        XCTAssertEqual(result.servers.filter(\.unrecognised).map(\.port), [31337])
    }

    // MARK: - Exposure

    func testMarksOnlyNonLoopbackBindingsAsExposed() throws {
        let result = try snapshot()
        XCTAssertFalse(try server(5173, in: result).exposed)
        XCTAssertFalse(try server(4321, in: result).exposed)
        XCTAssertTrue(try server(8000, in: result).exposed)
    }

    // MARK: - Duplicates

    /// Two servers from one project almost always means you forgot to stop the first.
    func testCountsDuplicateInstancesOfTheSameProject() throws {
        let result = try snapshot()
        XCTAssertEqual(try server(4321, in: result).duplicateCount, 2)
        XCTAssertEqual(try server(4322, in: result).duplicateCount, 2)
        XCTAssertEqual(try server(5173, in: result).duplicateCount, 1)
    }

    // MARK: - Ordering

    func testDevServersSortAheadOfEverythingElse() throws {
        let result = try snapshot()
        let firstNonDev = result.servers.firstIndex { !$0.isDevServer } ?? result.servers.count
        let lastDev = result.servers.lastIndex { $0.isDevServer } ?? -1
        XCTAssertLessThan(lastDev, firstNonDev)
    }

    // MARK: - The real machine

    /// The recorded capture from a real Mac with no dev servers running. Nothing in it
    /// should be mistaken for a project, and nothing normal should be flagged.
    func testRealCaptureProducesNoFalsePositives() throws {
        let inventory = PortInventory(
            runner: DevMachine.runner(
                listeners: try Fixture.text("lsof-listeners.txt"),
                processes: try Fixture.text("ps-listeners.txt"),
                cwds: try Fixture.text("lsof-cwd.txt")
            ),
            fileSystem: StubFileSystem(),
            home: DevMachine.home
        )
        let result = inventory.snapshot(includeBusyProcesses: false)

        XCTAssertFalse(result.servers.isEmpty)
        XCTAssertTrue(result.devServers.isEmpty, "no dev servers were running when this was captured")
        XCTAssertFalse(result.hasAlerts,
                       "ordinary macOS listeners must not be reported as unrecognised: "
                       + result.servers.filter(\.unrecognised).map(\.command).joined(separator: ", "))
    }

    func testRealCaptureGetsFriendlyNames() throws {
        let inventory = PortInventory(
            runner: DevMachine.runner(
                listeners: try Fixture.text("lsof-listeners.txt"),
                processes: try Fixture.text("ps-listeners.txt"),
                cwds: try Fixture.text("lsof-cwd.txt")
            ),
            fileSystem: StubFileSystem(),
            home: DevMachine.home
        )
        let labels = Set(inventory.snapshot(includeBusyProcesses: false).servers.compactMap(\.systemLabel))
        XCTAssertTrue(labels.contains("Continuity (AirDrop / Handoff)"))
        XCTAssertTrue(labels.contains("AirPlay / Control Center"))
    }
}
