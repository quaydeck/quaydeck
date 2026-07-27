import XCTest
@testable import QuaydeckCore

final class AdvisorTests: XCTestCase {

    private let advisor = Advisor()

    private func devServer(port: Int, project: String = "shop", memMB: Int = 100,
                           cpu: Double = 1, etime: String = "05:12") -> LocalServer {
        var server = LocalServer(port: port, pid: Int32(port), command: "node", args: "", cwd: "/")
        server.kind = .devServer
        server.project = project
        server.projectPath = "/Users/dev/code/\(project)"
        server.memMB = memMB
        server.cpu = cpu
        server.etime = etime
        return server
    }

    // MARK: - Rules

    func testFlagsAnUnrecognisedListenerAsCritical() {
        var miner = LocalServer(port: 31337, pid: 99, command: "miner", args: "/tmp/x", cwd: "/tmp")
        miner.kind = .unrecognised
        miner.exposed = true

        let advice = advisor.build(from: Snapshot(servers: [miner]))
        let item = advice.first { $0.kind == .unrecognised }
        XCTAssertEqual(item?.severity, .critical)
        XCTAssertTrue(item?.text.contains("reachable on your network") ?? false)
    }

    func testFlagsAServerReturningServerErrors() {
        var broken = devServer(port: 4321)
        broken.respondsHTTP = true
        broken.httpStatus = 502

        let advice = advisor.build(from: Snapshot(servers: [broken]))
        XCTAssertEqual(advice.first { $0.kind == .erroring }?.severity, .warning)
    }

    func testDoesNotFlagAHealthyServer() {
        var healthy = devServer(port: 4321)
        healthy.respondsHTTP = true
        healthy.httpStatus = 200
        XCTAssertTrue(advisor.build(from: Snapshot(servers: [healthy])).isEmpty)
    }

    func testFlagsMemoryHogsOverTheThreshold() {
        let advice = advisor.build(from: Snapshot(servers: [devServer(port: 4321, memMB: 1_400)]))
        XCTAssertEqual(advice.filter { $0.kind == .memoryHog }.count, 1)
        XCTAssertTrue(advisor.build(from: Snapshot(servers: [devServer(port: 4321, memMB: 900)])).isEmpty)
    }

    func testFlagsALongIdleServerAsInfo() {
        let stale = devServer(port: 4321, cpu: 0, etime: "3-00:00:00")
        XCTAssertEqual(advisor.build(from: Snapshot(servers: [stale])).first?.kind, .stale)
    }

    /// A server that is old but working is not stale.
    func testDoesNotFlagABusyLongRunningServer() {
        let working = devServer(port: 4321, cpu: 40, etime: "3-00:00:00")
        XCTAssertTrue(advisor.build(from: Snapshot(servers: [working])).isEmpty)
    }

    func testReportsDuplicatesOncePerProjectRatherThanOncePerPort() {
        var first = devServer(port: 4321)
        var second = devServer(port: 4322)
        first.duplicateCount = 2
        second.duplicateCount = 2

        let advice = advisor.build(from: Snapshot(servers: [first, second]))
        XCTAssertEqual(advice.filter { $0.kind == .duplicate }.count, 1)
    }

    /// One clear message beats two overlapping ones.
    func testSuppressesTheExposureWarningForAProjectAlreadyFlaggedAsDuplicated() {
        var first = devServer(port: 4321)
        var second = devServer(port: 4322)
        first.duplicateCount = 2; first.exposed = true
        second.duplicateCount = 2; second.exposed = true

        let advice = advisor.build(from: Snapshot(servers: [first, second]))
        XCTAssertTrue(advice.filter { $0.kind == .exposed }.isEmpty)
    }

    func testFlagsARunawayProcessWithNoPort() {
        let busy = BusyProcess(pid: 4242, command: "tsc", project: "shop",
                               projectPath: "/Users/dev/code/shop", cpu: 190, memMB: 400)
        let advice = advisor.build(from: Snapshot(busyProcesses: [busy]))
        XCTAssertEqual(advice.first?.kind, .runaway)
        XCTAssertEqual(advice.first?.pid, 4242)
        XCTAssertTrue(advice.first?.text.contains("190% CPU") ?? false)
    }

    // MARK: - Ordering and identity

    func testCriticalAdviceSortsFirst() {
        var miner = LocalServer(port: 31337, pid: 99, command: "miner", args: "/tmp/x", cwd: "/tmp")
        miner.kind = .unrecognised
        let stale = devServer(port: 4321, cpu: 0, etime: "3-00:00:00")

        let advice = advisor.build(from: Snapshot(servers: [stale, miner]))
        XCTAssertEqual(advice.first?.severity, .critical)
    }

    /// Identifiers must be stable across scans, or a dismissal would not stick.
    func testIdentifiersAreStableAcrossScans() {
        let snapshot = Snapshot(servers: [devServer(port: 4321, memMB: 1_400)])
        XCTAssertEqual(advisor.build(from: snapshot).map(\.id), advisor.build(from: snapshot).map(\.id))
    }
}
