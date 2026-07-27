import Foundation

/// Read-only filesystem access, behind a protocol so project detection can be tested
/// against an imaginary directory tree instead of whatever happens to be on disk.
public protocol FileSystemProbe: Sendable {
    func fileExists(at path: String) -> Bool
    func isDirectory(at path: String) -> Bool
    func contents(at path: String) -> Data?
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
}
