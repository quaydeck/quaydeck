import XCTest
@testable import QuaydeckCore

/// The runaway detector is the one piece that can nag you about your own machine, so
/// what it refuses to flag matters as much as what it flags.
final class BusyProcessTests: XCTestCase {

    private func detector(_ psAll: String) -> BusyProcessDetector {
        let runner = FixtureRunner([(exe: "ps", fragment: "-Ao", output: psAll)])
        return BusyProcessDetector(
            processes: ProcessSource(runner: runner),
            resolver: ProjectResolver(fileSystem: DevMachine.fileSystem,
                                      home: DevMachine.home)
        )
    }

    func testReportsAMemoryHogOnTheFirstPass() throws {
        let found = detector(try Fixture.text("ps-all.txt")).detect(excluding: [])
        let webpack = found.first { $0.pid == 2202 }
        XCTAssertNotNil(webpack, "a 1.9GB watcher with no port should be reported")
        XCTAssertEqual(webpack?.project, "docs-site")
        XCTAssertEqual(webpack?.memMB, 1_952)
    }

    /// Claude, editors, language servers and MCP servers are busy by design. Flagging
    /// them would train you to ignore the whole feature.
    func testNeverFlagsToolsThatAreBusyByDesign() throws {
        let found = detector(try Fixture.text("ps-all.txt")).detect(excluding: [])
        let flagged = Set(found.map(\.pid))
        for exempt: Int32 in [3301, 3302, 3303, 3304] {
            XCTAssertFalse(flagged.contains(exempt), "pid \(exempt) should be exempt")
        }
    }

    /// Anything already shown as a listening server belongs in the server list, not
    /// here, or it would appear twice.
    func testExcludesProcessesThatOwnAPort() throws {
        let found = detector(try Fixture.text("ps-all.txt")).detect(excluding: [2202])
        XCTAssertFalse(found.contains { $0.pid == 2202 })
    }

    /// CPU is a delta between scans, not a lifetime average, and a process must read
    /// hot several times before it counts. One quiet sample must report nothing.
    func testDoesNotFlagOnCPUFromASingleSample() throws {
        // tsc has burned 28 hours of CPU over its lifetime but is small in memory.
        // With no previous sample there is no rate to compare, so it stays quiet.
        let found = detector(try Fixture.text("ps-all.txt")).detect(excluding: [])
        XCTAssertFalse(found.contains { $0.pid == 2201 },
                       "a high lifetime CPU total is not evidence of being hot right now")
    }

    /// A runtime that cannot be traced to a project directory is not actionable.
    func testIgnoresRuntimesWithNoProject() {
        let found = detector("""
         9001  2000000     0:10.00 node /opt/something/server.js
        """).detect(excluding: [])
        XCTAssertTrue(found.isEmpty)
    }
}
