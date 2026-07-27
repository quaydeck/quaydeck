import Foundation

/// Reads branch and dirty state for a project.
///
/// Results are cached briefly: a scan runs every few seconds while the menu is open,
/// and forking `git status` per project on every one of those is pure waste.
public final class GitInspector: @unchecked Sendable {
    public struct Status: Hashable, Sendable {
        public let branch: String?
        public let dirty: Bool
        public static let unknown = Status(branch: nil, dirty: false)
    }

    private let runner: CommandRunner
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var cache: [String: (status: Status, at: Date)] = [:]
    private let gitPath = "/usr/bin/git"

    public init(runner: CommandRunner, ttl: TimeInterval = 8) {
        self.runner = runner
        self.ttl = ttl
    }

    public func status(at path: String, now: Date = Date()) -> Status {
        lock.lock()
        if let cached = cache[path], now.timeIntervalSince(cached.at) < ttl {
            lock.unlock()
            return cached.status
        }
        lock.unlock()

        let branch = runner.run(gitPath, ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var status = Status.unknown
        if !branch.isEmpty, branch != "HEAD", !branch.hasPrefix("fatal") {
            // -uno: ignore untracked files. node_modules and build output would
            // otherwise mark almost every project dirty forever.
            let porcelain = runner.run(gitPath, ["-C", path, "status", "--porcelain", "-uno"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            status = Status(branch: branch, dirty: !porcelain.isEmpty)
        }

        lock.lock()
        cache[path] = (status, now)
        lock.unlock()
        return status
    }
}
