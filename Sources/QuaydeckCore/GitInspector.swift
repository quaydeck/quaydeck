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
    /// Nil when this Mac has no usable git, in which case rows simply show no branch.
    private let gitPath: String?

    public init(runner: CommandRunner, ttl: TimeInterval = 8, gitPath: String? = "/usr/bin/git") {
        self.runner = runner
        self.ttl = ttl
        self.gitPath = gitPath
    }

    /// A git that will actually run. `/usr/bin/git` is only Apple's shim: on a Mac
    /// without the developer tools, running it opens the "install command line
    /// developer tools" dialog, and a scan every few seconds would open it every few
    /// seconds. So it is used only when the tools it dispatches to are installed.
    public static func locate(fileSystem: FileSystemProbe) -> String? {
        for direct in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileSystem.fileExists(at: direct) {
            return direct
        }
        let toolchains = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/git",
        ]
        return toolchains.contains(where: fileSystem.fileExists) ? "/usr/bin/git" : nil
    }

    /// `maxAge` overrides the default lifetime for one call: long while the menu is
    /// closed and nobody can see a branch name anyway.
    public func status(at path: String, now: Date = Date(), maxAge: TimeInterval? = nil) -> Status {
        lock.lock()
        if let cached = cache[path], now.timeIntervalSince(cached.at) < (maxAge ?? ttl) {
            lock.unlock()
            return cached.status
        }
        lock.unlock()

        guard let gitPath else { return .unknown }
        // One fork for both answers. -uno: ignore untracked files, or node_modules and
        // build output would mark almost every project dirty forever.
        let output = runner.run(gitPath, ["-C", path, "status", "--porcelain=v2", "--branch", "-uno"])
        let status = Self.parse(output)

        lock.lock()
        cache[path] = (status, now)
        lock.unlock()
        return status
    }

    /// `git status --porcelain=v2 --branch`: header lines start with "#", every other
    /// line is a changed tracked file.
    static func parse(_ output: String) -> Status {
        var branch: String?
        var dirty = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                branch = head == "(detached)" ? nil : head
            } else if !line.hasPrefix("#") {
                dirty = true
            }
        }
        guard branch != nil else { return .unknown }
        return Status(branch: branch, dirty: dirty)
    }
}
