import Foundation

/// Read-only filesystem access, behind a protocol so project detection can be tested
/// against an imaginary directory tree instead of whatever happens to be on disk.
public protocol FileSystemProbe: Sendable {
    func fileExists(at path: String) -> Bool
    func isDirectory(at path: String) -> Bool
    func contents(at path: String) -> Data?
    /// Names of the entries in a directory, or empty when it cannot be read.
    func contentsOfDirectory(at path: String) -> [String]
    /// The last `maxBytes` of a file. Session transcripts run to tens of megabytes and
    /// only their most recent lines are wanted.
    func tail(at path: String, maxBytes: Int) -> Data?
}

public struct RealFileSystem: FileSystemProbe {
    public init() {}

    public func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isDirectory(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public func contents(at path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    public func contentsOfDirectory(at path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    public func tail(at path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }
}

/// An imaginary tree: directories that exist, plus files with contents.
public struct StubFileSystem: FileSystemProbe {
    private let directories: Set<String>
    private let files: [String: Data]

    public init(directories: Set<String> = [], files: [String: String] = [:]) {
        self.directories = directories
        self.files = files.mapValues { Data($0.utf8) }
    }

    public func fileExists(at path: String) -> Bool {
        files[path] != nil || directories.contains(path)
    }

    public func isDirectory(at path: String) -> Bool { directories.contains(path) }

    public func contents(at path: String) -> Data? { files[path] }

    public func contentsOfDirectory(at path: String) -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let children = (Array(directories) + Array(files.keys))
            .filter { $0.hasPrefix(prefix) }
            .compactMap { $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init) }
        return Array(Set(children)).sorted()
    }

    public func tail(at path: String, maxBytes: Int) -> Data? {
        files[path].map { $0.suffix(maxBytes) }
    }
}
