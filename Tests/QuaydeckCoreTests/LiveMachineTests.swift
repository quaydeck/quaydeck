import XCTest
@testable import QuaydeckCore

/// Checks against the machine running the tests, so they only run when asked:
///
///     QUAYDECK_LIVE=1 swift test --filter LiveMachineTests
///
/// Run them after touching `KernelSource`: they compare it with the `lsof` and `ps`
/// output it replaces, and hold a scan to its cost budget.
final class LiveMachineTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QUAYDECK_LIVE"] == "1",
                          "set QUAYDECK_LIVE=1 to run against this machine")
    }

    func testTheKernelSeesWhatLsofSees() {
        let kernel = KernelSource()
        let viaLsof = Set(ListenerSource(runner: ShellRunner()).listeners()
            .map { "\($0.port)/\($0.pid)/\($0.exposed)" })
        let viaKernel = Set(kernel.listeners().map { "\($0.port)/\($0.pid)/\($0.exposed)" })
        XCTAssertEqual(viaKernel, viaLsof)

        let pids = Set(kernel.listeners().map(\.pid))
        let ps = ProcessSource(runner: ShellRunner()).info(for: pids)
        let direct = ProcessSource(kernel: kernel).info(for: pids)
        for pid in pids where ps[pid] != nil {
            XCTAssertEqual(direct[pid]?.ppid, ps[pid]?.ppid, "ppid of \(pid)")
            XCTAssertEqual(direct[pid]?.args, ps[pid]?.args, "args of \(pid)")
        }
        XCTAssertEqual(ListenerSource(kernel: kernel).workingDirectories(for: pids),
                       ListenerSource(runner: ShellRunner()).workingDirectories(for: pids))
    }

    /// A warm scan was about a second of wall time and half a second of CPU when it
    /// forked lsof and ps. Reading the kernel, it should stay far below that.
    func testAWarmScanStaysCheap() {
        let inventory = PortInventory(readsKernel: true)
        _ = inventory.snapshot()
        let start = Date()
        _ = inventory.snapshot()
        let elapsed = Date().timeIntervalSince(start)
        print("warm scan: \(Int(elapsed * 1000)) ms")
        XCTAssertLessThan(elapsed, 0.1)
    }
}
