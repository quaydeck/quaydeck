import Foundation

/// Finds dev-runtime processes that are burning CPU or memory while holding no
/// listening port: hung builds, stuck watchers, orphaned workers.
///
/// CPU is measured as a delta of accumulated CPU-seconds between scans rather than
/// `ps`'s lifetime average, so a build that finishes drops off the list immediately
/// instead of looking hot for the rest of the day. A process must read hot on several
/// consecutive scans before it is reported, which is what keeps normal compilation
/// from raising an alarm every time you save a file.
public final class BusyProcessDetector: @unchecked Sendable {

    static let runtimeNames: Set<String> = [
        "node", "python", "python3", "deno", "bun", "ruby", "tsc", "tsserver",
        "vite", "esbuild", "webpack", "next", "astro", "rollup", "parcel",
        "turbo", "nodemon", "ts-node", "tsx", "jest", "vitest", "swc", "rustc",
    ]

    /// Tools that are busy by design. Flagging these would be noise, every time.
    static let neverFlag = [
        "claude", ".claude/", "language-server", "languageserver", "mcp",
        "code helper", "cursor", "copilot", "spotlight", "mds_stores",
    ]

    private let processes: ProcessSource
    private let resolver: ProjectResolver
    private let lock = NSLock()
    private var samples: [Int32: (cpuSeconds: Double, at: Date, streak: Int)] = [:]

    /// Consecutive hot readings required before a process is reported.
    private let streakThreshold: Int
    /// Percentage of one core that counts as hot.
    private let hotThreshold: Int
    /// Memory that is worth reporting regardless of CPU.
    private let memoryThresholdMB: Int

    public init(processes: ProcessSource,
                resolver: ProjectResolver,
                streakThreshold: Int = 3,
                hotThreshold: Int = 70,
                memoryThresholdMB: Int = 1500) {
        self.processes = processes
        self.resolver = resolver
        self.streakThreshold = streakThreshold
        self.hotThreshold = hotThreshold
        self.memoryThresholdMB = memoryThresholdMB
    }

    public func detect(excluding listenerPIDs: Set<Int32>, now: Date = Date()) -> [BusyProcess] {
        let all = processes.allProcesses()
        var result: [BusyProcess] = []
        var fresh: [Int32: (Double, Date, Int)] = [:]

        lock.lock()
        let previous = samples
        lock.unlock()

        for process in all {
            guard !listenerPIDs.contains(process.pid) else { continue }
            guard isDevRuntime(process) else { continue }
            guard !isExempt(process) else { continue }
            guard let project = resolver.resolve(cwd: "/", args: process.args) else { continue }

            var instantCPU = 0
            var streak = 0
            if let last = previous[process.pid] {
                let elapsed = now.timeIntervalSince(last.at)
                if elapsed > 0.2 {
                    let delta = (process.cpuSeconds - last.cpuSeconds) / elapsed * 100
                    instantCPU = max(0, min(1000, Int(delta.rounded())))
                }
                streak = instantCPU > hotThreshold ? last.streak + 1 : 0
            }
            fresh[process.pid] = (process.cpuSeconds, now, streak)

            let memoryMB = process.rssKB / 1024
            if streak >= streakThreshold || memoryMB > memoryThresholdMB {
                result.append(BusyProcess(pid: process.pid,
                                          command: process.command,
                                          project: project.name,
                                          projectPath: project.path,
                                          cpu: instantCPU,
                                          memMB: memoryMB))
            }
        }

        // Replacing rather than merging prunes dead pids for free.
        lock.lock()
        samples = fresh
        lock.unlock()

        return result.sorted { ($0.cpu, $0.memMB) > ($1.cpu, $1.memMB) }
    }

    func isDevRuntime(_ process: ProcInfo) -> Bool {
        let command = process.command.lowercased()
        if Self.runtimeNames.contains(command) { return true }
        let lowered = process.args.lowercased()
        return Self.runtimeNames.contains { lowered.contains("/\($0) ") || lowered.contains(" \($0) ") }
    }

    func isExempt(_ process: ProcInfo) -> Bool {
        let lowered = process.args.lowercased()
        if process.args.contains(".app/Contents/") { return true }
        return Self.neverFlag.contains { lowered.contains($0) }
    }
}
