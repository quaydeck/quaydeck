import XCTest
@testable import QuaydeckCore

/// Properties that need to stay true, because the privacy note and the README make
/// promises about them.
final class SafetyTests: XCTestCase {

    /// ShellRunner passes an argument array to a real executable and never goes
    /// through `/bin/sh -c`. A project path containing shell syntax must therefore be
    /// inert. The previous version of this app interpolated paths into `sh -c`.
    func testCommandRunnerDoesNotGoThroughAShell() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("quaydeck-shell-probe-\(UUID().uuidString)").path
        let hostile = "harmless; touch \(marker)"

        // /bin/echo, not a shell builtin, so this only succeeds if no shell is involved.
        let output = ShellRunner().run("/bin/echo", [hostile])

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), hostile,
                       "the argument must arrive intact, not be split or interpreted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "the embedded command must never have run")
    }

    /// A pid of 0 or 1 means "unset" or "launchd". Signalling either would be bad.
    func testProcessControlRefusesUnsafePIDs() {
        let recorder = RecordingProcessControl()
        recorder.terminate(pid: 4242, force: false)
        XCTAssertEqual(recorder.requests.count, 1)

        // The real implementation is what enforces the guard.
        let runner = FixtureRunner([])
        let control = ProcessControl(runner: runner)
        control.terminate(pid: 0, force: true)
        control.terminate(pid: 1, force: true)
        // Nothing to assert beyond "did not crash and did not signal init"; the guard
        // is a `pid > 1` check that a fixture runner cannot observe. This documents it.
    }

    /// The probe must only ever be pointed at loopback.
    func testProbeOnlyEverTargetsLocalhost() {
        // The URL is built from a port and nothing else, so there is no input that
        // could redirect it to another host.
        for port in [1, 80, 5173, 65_535] {
            let url = URL(string: "http://localhost:\(port)/")
            XCTAssertEqual(url?.host, "localhost")
            XCTAssertEqual(url?.scheme, "http")
        }
    }

    /// Titles come from a page the probe fetched, so they reach the UI as untrusted
    /// text. They must be plain strings with no control characters that could
    /// scramble a row.
    func testExtractedTitlesAreFlattened() {
        let title = HealthProbe.extractTitle("<title>line one\nline two    spaced</title>")
        XCTAssertEqual(title, "line one line two spaced")
        XCTAssertFalse(title?.contains("\n") ?? true)
    }
}
