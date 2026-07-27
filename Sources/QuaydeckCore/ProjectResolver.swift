import Foundation

/// A resolved project: where it lives and what to call it.
public struct Project: Hashable, Sendable {
    public let path: String
    public let name: String
    /// Root of the enclosing git repository, when there is one. May differ from `path`
    /// in a monorepo, where `path` is the individual app and this is the repo.
    public let gitRoot: String?
}

/// Works out which project a process belongs to.
///
/// The rule is: walk up from the process's working directory (or from any absolute
/// path in its argument vector) until we hit a directory that looks like the root of
/// a project, and name it from its manifest. Nothing here is specific to how any one
/// person organises their disk.
public struct ProjectResolver: Sendable {

    /// Files that mark a directory as the root of something you work on, strongest
    /// signal first. `.quaydeck` is an explicit override for anyone whose layout we
    /// guess wrong.
    static let markers = [
        ".quaydeck",
        "package.json",
        "Cargo.toml",
        "go.mod",
        "pyproject.toml",
        "composer.json",
        "Gemfile",
        "deno.json",
        "deno.jsonc",
        "mix.exs",
        "pubspec.yaml",
        "build.gradle",
        "build.gradle.kts",
        "pom.xml",
        "Package.swift",
        "requirements.txt",
        ".git",
    ]

    /// How far up we are willing to walk before giving up.
    private static let maxDepth = 12

    private let fileSystem: FileSystemProbe
    private let home: String
    /// Directories the user has told us hold their projects. Used only to produce a
    /// nicer name when no manifest is found.
    private let userRoots: [String]

    public init(fileSystem: FileSystemProbe = RealFileSystem(),
                home: String = NSHomeDirectory(),
                userRoots: [String] = []) {
        self.fileSystem = fileSystem
        self.home = home
        self.userRoots = userRoots
    }

    /// Resolve a project from a working directory and an argument vector.
    /// `cwd` may be "/" for processes launched by launchd, in which case we fall back
    /// entirely to paths mentioned in the arguments.
    public func resolve(cwd: String, args: String) -> Project? {
        for candidate in candidatePaths(cwd: cwd, args: args) {
            if let project = project(containing: candidate) { return project }
        }
        // Nothing carried a manifest. If a candidate sits inside a directory the user
        // nominated as a project root, take the first component below that root.
        for candidate in candidatePaths(cwd: cwd, args: args) {
            if let project = projectFromUserRoot(candidate) { return project }
        }
        return nil
    }

    // MARK: - Candidates

    /// Paths worth investigating, best first: the working directory, then any
    /// absolute path that appears in the arguments.
    func candidatePaths(cwd: String, args: String) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func add(_ path: String) {
            let cleaned = normalise(path)
            guard cleaned != "/", cleaned != home, !cleaned.isEmpty else { return }
            guard seen.insert(cleaned).inserted else { return }
            candidates.append(cleaned)
        }

        add(cwd)
        for token in args.split(separator: " ") {
            let text = String(token)
            guard text.hasPrefix("/") else { continue }
            // Skip the interpreter itself and other system binaries: they never
            // identify the project.
            if text.hasPrefix("/usr/") || text.hasPrefix("/bin/") || text.hasPrefix("/sbin/")
                || text.hasPrefix("/System/") || text.hasPrefix("/opt/homebrew/bin/")
                || text.hasPrefix("/opt/homebrew/Cellar/") { continue }
            add(text)
        }
        return candidates
    }

    /// Strip a trailing slash, and drop a trailing filename so "/a/b/vite.config.js"
    /// starts its walk at "/a/b".
    ///
    /// The directory check matters: a project legitimately named "my.site" must not be
    /// mistaken for a file and truncated to its parent.
    private func normalise(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        guard !fileSystem.isDirectory(at: result) else { return result }
        guard let slash = result.lastIndex(of: "/"), slash != result.startIndex else { return result }
        return String(result[result.startIndex..<slash])
    }

    // MARK: - Walking

    /// Walk up from `start` looking for the innermost directory carrying a marker.
    /// The innermost one is what you want: in a monorepo it identifies the individual
    /// app rather than the whole repository.
    func project(containing start: String) -> Project? {
        var current = start
        var depth = 0
        var innermost: String?
        var gitRoot: String?

        while depth < Self.maxDepth, current.count > 1, current != home {
            if innermost == nil {
                for marker in Self.markers where marker != ".git" {
                    if fileSystem.fileExists(at: current + "/" + marker) {
                        innermost = current
                        break
                    }
                }
            }
            if fileSystem.fileExists(at: current + "/.git") {
                gitRoot = current
                // A git root above a manifest is still the repo; keep walking only if
                // we have not found a manifest yet.
                if innermost == nil { innermost = current }
                break
            }
            guard let slash = current.lastIndex(of: "/") else { break }
            let parent = String(current[current.startIndex..<slash])
            if parent.isEmpty { break }
            current = parent
            depth += 1
        }

        guard let path = innermost else { return nil }
        return Project(path: path, name: name(for: path), gitRoot: gitRoot)
    }

    /// Fall back for directories with no manifest at all: if the path is under a root
    /// the user nominated, the project is the first directory below that root.
    func projectFromUserRoot(_ path: String) -> Project? {
        for root in userRoots {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(prefix) else { continue }
            let remainder = String(path.dropFirst(prefix.count))
            guard let first = remainder.split(separator: "/").first else { continue }
            let projectPath = prefix + first
            return Project(path: projectPath, name: String(first), gitRoot: nil)
        }
        return nil
    }

    // MARK: - Naming

    /// Prefer the manifest's own name, fall back to the directory name.
    func name(for path: String) -> String {
        if let packageName = manifestName(at: path) { return packageName }
        return String(path.split(separator: "/").last ?? "project")
    }

    private func manifestName(at path: String) -> String? {
        if let data = fileSystem.contents(at: path + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            // "@acme/web" -> "web"
            if let slash = name.lastIndex(of: "/") {
                return String(name[name.index(after: slash)...])
            }
            return name
        }
        return nil
    }
}
