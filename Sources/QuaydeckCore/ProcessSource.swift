import Foundation

/// One process as reported by `ps`.
/// (Named `ProcInfo`, not `ProcessInfo`, to avoid shadowing Foundation's type.)
public struct ProcInfo: Hashable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// Basename of argv[0].
    public let command: String
    /// Full argument vector.
    public let args: String
    /// Raw elapsed wall-clock time, e.g. "01:23:45".
    public let etime: String
    public let cpu: Double
    /// Resident set size in KB, as `ps` reports it.
    public let rssKB: Int
    /// Accumulated CPU time in seconds. Only populated by `allProcesses()`.
    public let cpuSeconds: Double
}

/// Reads process tables out of `ps`.
public struct ProcessSource: Sendable {
    private let runner: CommandRunner?
    private let kernel: KernelSource?
    private static let psPath = "/bin/ps"

    /// Reads recorded or real `ps` output. The path fixtures take.
    public init(runner: CommandRunner) {
        self.runner = runner
        self.kernel = nil
    }

    /// Asks the kernel directly. The path the app takes.
    public init(kernel: KernelSource) {
        self.runner = nil
        self.kernel = kernel
    }

    /// Details for a specific set of pids.
    public func info(for pids: Set<Int32>) -> [Int32: ProcInfo] {
        guard !pids.isEmpty else { return [:] }
        if let kernel {
            let now = Date()
            var map: [Int32: ProcInfo] = [:]
            for pid in pids { map[pid] = kernel.process(pid, now: now) }
            return map
        }
        guard let runner else { return [:] }
        let list = pids.map(String.init).sorted().joined(separator: ",")
        // -ww disables the column-width truncation that mangles long executable paths.
        let output = runner.run(Self.psPath, ["-ww", "-o", "pid=,ppid=,etime=,pcpu=,rss=,args=", "-p", list])
        return Self.parseDetailed(output)
    }

    /// Every process on the machine, with accumulated CPU time. Used to spot runaway
    /// builds that hold no port. `named` lets the kernel path skip reading the
    /// arguments of the hundreds of processes that cannot matter; `ps` returns
    /// everything regardless.
    public func allProcesses(named: (String) -> Bool = { _ in true }) -> [ProcInfo] {
        if let kernel { return kernel.processes(named: named) }
        guard let runner else { return [] }
        let output = runner.run(Self.psPath, ["-Ao", "pid=,rss=,time=,args="])
        return Self.parseAll(output)
    }

    /// Look up a single pid. Used when walking a parent chain past the processes we
    /// already asked about.
    public func one(_ pid: Int32) -> ProcInfo? {
        if let kernel { return kernel.process(pid) }
        guard let runner else { return nil }
        let output = runner.run(Self.psPath, ["-ww", "-o", "pid=,ppid=,etime=,pcpu=,rss=,args=", "-p", "\(pid)"])
        return Self.parseDetailed(output)[pid]
    }

    // MARK: - Parsing

    /// Columns: pid ppid etime pcpu rss <argv...>. The first five never contain a
    /// space, so we cap the split at five and keep argv intact however many spaces
    /// the binary path has.
    static func parseDetailed(_ output: String) -> [Int32: ProcInfo] {
        var map: [Int32: ProcInfo] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count == 6,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            let args = String(parts[5])
            map[pid] = ProcInfo(
                pid: pid,
                ppid: ppid,
                command: basenameOfExecutable(args),
                args: args,
                etime: String(parts[2]),
                cpu: Double(parts[3]) ?? 0,
                rssKB: Int(parts[4]) ?? 0,
                cpuSeconds: 0
            )
        }
        return map
    }

    /// Columns: pid rss time <argv...>.
    static func parseAll(_ output: String) -> [ProcInfo] {
        var result: [ProcInfo] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]) else { continue }
            let args = String(parts[3])
            result.append(ProcInfo(
                pid: pid,
                ppid: 0,
                command: basenameOfExecutable(args),
                args: args,
                etime: "",
                cpu: 0,
                rssKB: Int(parts[1]) ?? 0,
                cpuSeconds: parseCPUTime(String(parts[2]))
            ))
        }
        return result
    }

    /// argv[0] is everything up to the first argument that looks like a flag or a
    /// second path, which we approximate by taking the whole string when it has no
    /// space, and otherwise the longest prefix that names an existing-looking path.
    /// In practice `lsof`'s command name is preferred over this; it only has to be
    /// good enough for processes we never saw through lsof.
    static func basenameOfExecutable(_ args: String) -> String {
        let firstToken = args.split(separator: " ", maxSplits: 1).first.map(String.init) ?? args
        return String(firstToken.split(separator: "/").last ?? Substring(firstToken))
    }

    /// "mm:ss.ss", "hh:mm:ss" or "dd-hh:mm:ss" -> seconds.
    static func parseCPUTime(_ text: String) -> Double {
        var days = 0.0
        var rest = text
        if let dash = text.firstIndex(of: "-") {
            days = Double(text[..<dash]) ?? 0
            rest = String(text[text.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        var hours = 0.0, minutes = 0.0, seconds = 0.0
        switch parts.count {
        case 3: hours = parts[0]; minutes = parts[1]; seconds = parts[2]
        case 2: minutes = parts[0]; seconds = parts[1]
        case 1: seconds = parts[0]
        default: return 0
        }
        return ((days * 24 + hours) * 60 + minutes) * 60 + seconds
    }
}
