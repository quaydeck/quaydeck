import XCTest
@testable import QuaydeckCore

final class ListenerParsingTests: XCTestCase {

    func testParsesBindingsAndExposure() {
        XCTAssertEqual(ListenerSource.parseBinding("127.0.0.1:4321")?.port, 4321)
        XCTAssertEqual(ListenerSource.parseBinding("127.0.0.1:4321")?.exposed, false)
        XCTAssertEqual(ListenerSource.parseBinding("[::1]:4321")?.exposed, false)
        XCTAssertEqual(ListenerSource.parseBinding("localhost:3000")?.exposed, false)
        XCTAssertEqual(ListenerSource.parseBinding("*:8000")?.exposed, true)
        XCTAssertEqual(ListenerSource.parseBinding("192.168.1.20:8080")?.exposed, true)
        XCTAssertNil(ListenerSource.parseBinding("not-a-socket"))
    }

    /// 127.0.0.0/8 is all loopback, not just 127.0.0.1.
    func testTreatsWholeLoopbackRangeAsLocal() {
        XCTAssertEqual(ListenerSource.parseBinding("127.0.0.2:5000")?.exposed, false)
    }

    func testFieldsAccumulateAgainstTheCurrentProcess() throws {
        let output = try Fixture.text("lsof-dev.txt")
        let listeners = ListenerSource.parseListeners(output)

        XCTAssertEqual(listeners.first { $0.port == 5173 }?.pid, 1001)
        XCTAssertEqual(listeners.first { $0.port == 5173 }?.command, "node")
        XCTAssertEqual(listeners.first { $0.port == 31337 }?.command, "miner")
        XCTAssertEqual(listeners.first { $0.port == 31337 }?.exposed, true)
    }

    /// One server bound to both IPv4 and IPv6 shows up as two lsof rows.
    func testDualStackServerAppearsTwiceBeforeCollapsing() throws {
        let listeners = ListenerSource.parseListeners(try Fixture.text("lsof-dev.txt"))
        XCTAssertEqual(listeners.filter { $0.port == 4321 }.count, 2)
    }

    func testParsesWorkingDirectories() throws {
        let map = ListenerSource.parseWorkingDirectories(try Fixture.text("lsof-cwd-dev.txt"))
        XCTAssertEqual(map[1001], "/Users/dev/code/acme-site")
        XCTAssertEqual(map[1005], "/")
    }
}

final class ProcessParsingTests: XCTestCase {

    func testParsesDetailedColumns() throws {
        let map = ProcessSource.parseDetailed(try Fixture.text("ps-dev.txt"))
        let vite = try XCTUnwrap(map[1001])
        XCTAssertEqual(vite.ppid, 900)
        XCTAssertEqual(vite.etime, "05:12")
        XCTAssertEqual(vite.cpu, 1.2, accuracy: 0.001)
        XCTAssertEqual(vite.rssKB, 184_320)
        XCTAssertTrue(vite.args.hasSuffix("--port 5173"))
    }

    /// The whole reason for capping the split at five columns: a binary path with a
    /// space in it must survive intact.
    func testKeepsArgumentVectorsContainingSpaces() throws {
        let map = ProcessSource.parseDetailed(try Fixture.text("ps-listeners.txt"))
        let drive = map.values.first { $0.args.contains("Google Drive") }
        XCTAssertNotNil(drive, "a binary path containing a space must not be split")
        XCTAssertTrue(drive?.args.contains("--single_process") ?? false,
                      "arguments after the spaced path must be preserved")
    }

    func testParsesCPUTimeInEveryFormat() {
        XCTAssertEqual(ProcessSource.parseCPUTime("12.34"), 12.34, accuracy: 0.001)
        XCTAssertEqual(ProcessSource.parseCPUTime("01:30"), 90, accuracy: 0.001)
        XCTAssertEqual(ProcessSource.parseCPUTime("02:00:00"), 7_200, accuracy: 0.001)
        XCTAssertEqual(ProcessSource.parseCPUTime("1-00:00:00"), 86_400, accuracy: 0.001)
    }

    func testParsesAllProcessesColumns() throws {
        let all = ProcessSource.parseAll(try Fixture.text("ps-all.txt"))
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { $0.pid > 0 })
    }
}

final class UptimeTests: XCTestCase {

    private func server(etime: String) -> LocalServer {
        var server = LocalServer(port: 1, pid: 1, command: "node", args: "", cwd: "/")
        server.etime = etime
        return server
    }

    func testParsesEveryElapsedTimeFormat() {
        XCTAssertEqual(server(etime: "42").uptimeSeconds, 42)
        XCTAssertEqual(server(etime: "01:30").uptimeSeconds, 90)
        XCTAssertEqual(server(etime: "02:00:00").uptimeSeconds, 7_200)
        XCTAssertEqual(server(etime: "3-04:05:06").uptimeSeconds, 273_906)
        XCTAssertNil(server(etime: "").uptimeSeconds)
    }

    func testFormatsUptimeAtTheRightGranularity() {
        XCTAssertEqual(server(etime: "42").uptimeText, "42s")
        XCTAssertEqual(server(etime: "05:12").uptimeText, "5m")
        XCTAssertEqual(server(etime: "02:30:00").uptimeText, "2h 30m")
        XCTAssertEqual(server(etime: "3-04:05:06").uptimeText, "3d 4h")
    }

    func testMarksRecentlyStartedServersAsNew() {
        XCTAssertTrue(server(etime: "10").isNew)
        XCTAssertFalse(server(etime: "05:12").isNew)
    }
}

final class TitleExtractionTests: XCTestCase {

    func testExtractsTitleIgnoringCaseAndAttributes() {
        XCTAssertEqual(HealthProbe.extractTitle("<html><TITLE>Shop</TITLE>"), "Shop")
        XCTAssertEqual(HealthProbe.extractTitle("<title data-x=\"1\">Shop</title>"), "Shop")
    }

    func testCollapsesWhitespaceAndDecodesEntities() {
        XCTAssertEqual(HealthProbe.extractTitle("<title>Acme   &amp;  Co\n</title>"), "Acme & Co")
    }

    func testReturnsNilWhenThereIsNoTitle() {
        XCTAssertNil(HealthProbe.extractTitle("<html><body>hi</body></html>"))
        XCTAssertNil(HealthProbe.extractTitle("<title></title>"))
        XCTAssertNil(HealthProbe.extractTitle("<title>unclosed"))
    }
}
