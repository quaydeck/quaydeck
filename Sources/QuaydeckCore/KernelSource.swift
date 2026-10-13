import Darwin
import Foundation

/// Reads listening sockets and process details straight from the kernel, through the
/// same libproc and sysctl calls `lsof` and `ps` make internally, without starting
/// either. Forking those tools was about 90% of a scan's cost: roughly 100 ms each,
/// eight times per scan.
///
/// `lsof` and `ps` remain the path for recorded fixtures, which is how bug reports
/// become tests. This type is the path the app takes on a real machine.
public final class KernelSource: @unchecked Sendable {
    private let lock = NSLock()
    /// Previous CPU reading per process, so CPU is "now", not a lifetime average.
    private var cpuSamples: [Int32: (seconds: Double, at: Date)] = [:]
    private let args = ProcArgsReader()

    /// Mach ticks to nanoseconds. On Apple silicon CPU times come in ticks, not ns.
    private static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }()

    public init() {}

    // MARK: - Sockets

    /// Every listening TCP socket this user can see, one entry per binding, exactly
    /// like `lsof -iTCP -sTCP:LISTEN`.
    public func listeners() -> [Listener] {
        var result: [Listener] = []
        for pid in Self.allPIDs() {
            let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard fdBytes > 0 else { continue }
            let stride = MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdBytes) / stride + 8)
            let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
            guard filled > 0 else { continue }

            var name: String?
            for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var socket = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                      socket.psi.soi_kind == SOCKINFO_TCP else { continue }
                let tcp = socket.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }

                let endpoint = tcp.tcpsi_ini
                let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: endpoint.insi_lport)))
                guard port > 0 else { continue }
                if name == nil { name = Self.name(of: pid) }
                result.append(Listener(port: port, pid: pid, command: name ?? "",
                                       exposed: !Self.isLoopback(endpoint)))
            }
        }
        return result
    }

    static func isLoopback(_ endpoint: in_sockinfo) -> Bool {
        if endpoint.insi_vflag & UInt8(INI_IPV4) != 0 {
            let address = UInt32(bigEndian: endpoint.insi_laddr.ina_46.i46a_addr4.s_addr)
            return address >> 24 == 127
        }
        let bytes = withUnsafeBytes(of: endpoint.insi_laddr.ina_6) { Array($0) }
        guard bytes.count == 16 else { return false }
        // ::1
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        // ::ffff:127.x.x.x
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127 {
            return true
        }
        return false
    }

    // MARK: - Processes

    public func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = Self.string(fromTuple: info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// One process in `ps`'s terms. Nil for a process that has gone, or that belongs
    /// to another user.
    public func process(_ pid: Int32, now: Date = Date()) -> ProcInfo? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }

        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
        let cpuSeconds = hasTask
            ? Double(task.pti_total_user + task.pti_total_system) * Self.nanosecondsPerTick / 1e9
            : 0

        let started = Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec)
                           + Double(bsd.pbi_start_tvusec) / 1e6)
        let elapsed = max(0, now.timeIntervalSince(started))
        let name = Self.string(fromTuple: bsd.pbi_name).isEmpty
            ? Self.string(fromTuple: bsd.pbi_comm)
            : Self.string(fromTuple: bsd.pbi_name)
        let argv = args.arguments(of: pid)

        return ProcInfo(
            pid: pid,
            ppid: Int32(bsd.pbi_ppid),
            command: argv.isEmpty ? name : ProcessSource.basenameOfExecutable(argv),
            args: argv.isEmpty ? name : argv,
            etime: Self.etime(elapsed),
            cpu: cpuPercent(pid: pid, seconds: cpuSeconds, elapsed: elapsed, now: now),
            rssKB: hasTask ? Int(task.pti_resident_size / 1024) : 0,
            cpuSeconds: cpuSeconds
        )
    }

    /// Every process whose name passes `named`, with full details. The name check
    /// comes first so the argument vector, the expensive part, is read only for the
    /// handful of processes that could matter.
    public func processes(named: (String) -> Bool, now: Date = Date()) -> [ProcInfo] {
        Self.allPIDs().compactMap { pid in
            guard let name = Self.name(of: pid), named(name) else { return nil }
            return process(pid, now: now)
        }
    }

    /// CPU over the time since the last look at this process, falling back to the
    /// lifetime average the first time. `ps` reports a decaying average instead, which
    /// keeps a finished build looking busy for a while.
    private func cpuPercent(pid: Int32, seconds: Double, elapsed: TimeInterval, now: Date) -> Double {
        lock.lock(); defer { lock.unlock() }
        let previous = cpuSamples[pid]
        cpuSamples[pid] = (seconds, now)
        if cpuSamples.count > 4_096 { cpuSamples.removeAll(keepingCapacity: true) }
        if let previous, now.timeIntervalSince(previous.at) > 0.5, seconds >= previous.seconds {
            return (seconds - previous.seconds) / now.timeIntervalSince(previous.at) * 100
        }
        return elapsed > 1 ? seconds / elapsed * 100 : 0
    }

    // MARK: - Helpers

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    static func name(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `ps`'s elapsed format: "mm:ss", "hh:mm:ss" or "dd-hh:mm:ss".
    static func etime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400, hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60, secs = total % 60
        if days > 0 { return String(format: "%02d-%02d:%02d:%02d", days, hours, minutes, secs) }
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// C fixed-size char arrays arrive in Swift as tuples.
    static func string<T>(fromTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// Reads KERN_PROCARGS2 into one reusable buffer. The kernel's argument limit is a
/// megabyte; allocating that per process per scan was most of the cost of reading
/// a single environment variable.
final class ProcArgsReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []

    private static let argmax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 0 }
        return Int(value)
    }()

    /// Runs `body` over the raw block while holding the buffer. Nil when the kernel
    /// will not hand it out (another user's process, or one that has exited).
    func withProcArgs<T>(of pid: Int32, _ body: (ArraySlice<UInt8>) -> T) -> T? {
        guard pid > 0, Self.argmax > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if buffer.count != Self.argmax { buffer = [UInt8](repeating: 0, count: Self.argmax) }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Self.argmax
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }
        guard status == 0, size > MemoryLayout<Int32>.size else { return nil }
        return body(buffer[0..<size])
    }

    /// The argument vector joined by spaces, as `ps -o args=` prints it.
    func arguments(of pid: Int32) -> String {
        // A process that rewrote its title ("Raycast Backend") leaves empty arguments
        // behind; `ps` trims them, so this does too.
        withProcArgs(of: pid) {
            ProcArgs.argv(in: $0).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        } ?? ""
    }
}

/// Layout of a KERN_PROCARGS2 block: argc as a 32-bit int, the executable path, NUL
/// padding, argc argument strings, then the environment as `KEY=value` strings ending
/// at an empty one.
enum ProcArgs {
    static func argv(in bytes: ArraySlice<UInt8>) -> [String] {
        var result: [String] = []
        walk(bytes) { index, isArgument, start, end in
            guard isArgument else { return false }
            result.append(String(decoding: bytes[start..<end], as: UTF8.self))
            return true
        }
        return result
    }

    static func environment(in bytes: ArraySlice<UInt8>, wanted: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        walk(bytes) { _, isArgument, start, end in
            guard !isArgument else { return true }
            if let equals = bytes[start..<end].firstIndex(of: UInt8(ascii: "=")),
               let key = String(bytes: bytes[start..<equals], encoding: .utf8),
               wanted.contains(key) {
                result[key] = String(bytes: bytes[(equals + 1)..<end], encoding: .utf8) ?? ""
            }
            return true
        }
        return result
    }

    /// Calls `visit` for each argument, then each environment entry, until it returns
    /// false or the environment ends.
    private static func walk(_ bytes: ArraySlice<UInt8>,
                             _ visit: (_ index: Int, _ isArgument: Bool, _ start: Int, _ end: Int) -> Bool) {
        let base = bytes.startIndex
        guard bytes.count > 4 else { return }
        let argc = Int(bytes[base]) | Int(bytes[base + 1]) << 8
            | Int(bytes[base + 2]) << 16 | Int(bytes[base + 3]) << 24
        var index = base + 4
        let end = bytes.endIndex

        while index < end, bytes[index] != 0 { index += 1 }
        while index < end, bytes[index] == 0 { index += 1 }

        var seen = 0
        while index < end {
            let start = index
            while index < end, bytes[index] != 0 { index += 1 }
            let isArgument = seen < argc
            if !isArgument && index == start { return }
            if !visit(seen, isArgument, start, index) { return }
            seen += 1
            index += 1
        }
    }
}
