import Foundation

/// A running container, as `docker ps` describes it.
public struct ContainerInfo: Hashable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    /// Docker's own phrasing, e.g. "Up 3 minutes (healthy)".
    public let status: String
    public let composeProject: String?
    public let composeService: String?
    /// The directory `docker compose up` ran in, when compose started it.
    public let composeDirectory: String?

    public init(id: String, name: String, image: String, status: String,
                composeProject: String? = nil, composeService: String? = nil,
                composeDirectory: String? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.status = status
        self.composeProject = composeProject
        self.composeService = composeService
        self.composeDirectory = composeDirectory
    }

    /// A locally built image has no name, only a digest: "sha256:2241a1b2…" reads
    /// better as its first twelve characters, the way `docker images` shows it.
    public var imageLabel: String {
        guard image.hasPrefix("sha256:") else { return image }
        return String(image.dropFirst("sha256:".count).prefix(12))
    }
}

/// One host port a container publishes, and the port inside the container behind it.
public struct PublishedPort: Hashable, Sendable {
    public let container: ContainerInfo
    public let containerPort: Int
}

/// Maps published host ports to the containers behind them.
///
/// On a Mac every published port is held by the container runtime's proxy process
/// (`com.docker.backend`, OrbStack, Colima's `limactl`), so `lsof` alone only ever says
/// "Docker". `docker ps` says which container, and which compose project it belongs to.
/// It talks to the daemon over its local socket and is asked only when a runtime's
/// proxy is actually holding a port.
public struct DockerSource: Sendable {
    private let runner: CommandRunner
    private let fileSystem: FileSystemProbe
    private let home: String

    /// A wedged daemon can make `docker ps` hang indefinitely; a scan never waits on it.
    static let timeout: TimeInterval = 3

    /// Process names that hold ports on behalf of containers.
    static let runtimeNeedles = ["com.docker", "vpnkit", "docker", "orbstack", "colima",
                                 "limactl", "rancher"]

    public init(runner: CommandRunner, fileSystem: FileSystemProbe, home: String) {
        self.runner = runner
        self.fileSystem = fileSystem
        self.home = home
    }

    public static func isContainerRuntime(command: String) -> Bool {
        let lowered = command.lowercased()
        return runtimeNeedles.contains { lowered.contains($0) }
    }

    /// The docker CLI, wherever Docker Desktop, Homebrew, OrbStack or Rancher put it.
    public var cliPath: String? {
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            home + "/.orbstack/bin/docker",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
            home + "/.rd/bin/docker",
        ]
        return candidates.first { fileSystem.fileExists(at: $0) }
    }

    /// Host port to container, for every TCP port a running container publishes.
    public func publishedPorts() -> [Int: PublishedPort] {
        guard let cli = cliPath else { return [:] }
        let format = [
            "{{.ID}}", "{{.Names}}", "{{.Image}}", "{{.Status}}", "{{.Ports}}",
            #"{{.Label "com.docker.compose.project"}}"#,
            #"{{.Label "com.docker.compose.service"}}"#,
            #"{{.Label "com.docker.compose.project.working_dir"}}"#,
        ].joined(separator: "\\t")
        let output = runner.run(cli, ["ps", "--no-trunc", "--format", format], timeout: Self.timeout)
        return Self.parse(output)
    }

    // MARK: - Parsing

    static func parse(_ output: String) -> [Int: PublishedPort] {
        var result: [Int: PublishedPort] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, !fields[0].isEmpty else { continue }
            func field(_ index: Int) -> String? {
                guard index < fields.count else { return nil }
                let value = fields[index].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            let container = ContainerInfo(
                id: fields[0],
                // Legacy links make Names a comma-separated list; the first is the name.
                name: fields[1].split(separator: ",").first.map(String.init) ?? fields[1],
                image: fields[2],
                status: fields[3],
                composeProject: field(5),
                composeService: field(6),
                composeDirectory: field(7)
            )
            for mapping in parsePorts(fields[4]) where result[mapping.host] == nil {
                result[mapping.host] = PublishedPort(container: container, containerPort: mapping.container)
            }
        }
        return result
    }

    /// "127.0.0.1:80->80/tcp, [::]:5432->5432/tcp, 0.0.0.0:8025-8026->8025-8026/tcp,
    /// 9000/tcp" -> host/container pairs. Unpublished and UDP ports are skipped.
    static func parsePorts(_ text: String) -> [(host: Int, container: Int)] {
        var result: [(host: Int, container: Int)] = []
        for item in text.split(separator: ",") {
            let entry = item.trimmingCharacters(in: .whitespaces)
            guard let arrow = entry.range(of: "->") else { continue }
            let hostSide = entry[..<arrow.lowerBound]
            let containerSide = entry[arrow.upperBound...]
            guard containerSide.hasSuffix("/tcp"),
                  let colon = hostSide.lastIndex(of: ":") else { continue }
            let hosts = range(hostSide[hostSide.index(after: colon)...])
            let containers = range(containerSide.dropLast(4))
            guard !hosts.isEmpty, !containers.isEmpty else { continue }
            for (offset, host) in hosts.enumerated() {
                let inside = offset < containers.count ? containers[offset] : containers[0]
                result.append((host, inside))
            }
        }
        return result
    }

    /// "8025" -> [8025], "8025-8026" -> [8025, 8026].
    private static func range<S: StringProtocol>(_ text: S) -> [Int] {
        let parts = text.split(separator: "-")
        if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]), low <= high, high - low < 1_000 {
            return Array(low...high)
        }
        return Int(text).map { [$0] } ?? []
    }
}

/// Stopping and restarting containers, through the docker CLI rather than by signalling
/// the runtime's proxy process, which would take every container down with it.
public protocol ContainerControlling: Sendable {
    func stop(containerID: String)
    func restart(containerID: String)
}

public struct ContainerControl: ContainerControlling {
    private let runner: CommandRunner
    private let docker: DockerSource

    /// `docker stop` waits up to ten seconds for a graceful exit before killing.
    private static let timeout: TimeInterval = 20

    public init(runner: CommandRunner, fileSystem: FileSystemProbe = RealFileSystem(),
                home: String = NSHomeDirectory()) {
        self.runner = runner
        self.docker = DockerSource(runner: runner, fileSystem: fileSystem, home: home)
    }

    public func stop(containerID: String) { run("stop", containerID) }
    public func restart(containerID: String) { run("restart", containerID) }

    private func run(_ verb: String, _ id: String) {
        // An id from `docker ps` is hex. Anything else is not passed on.
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit), let cli = docker.cliPath else { return }
        _ = runner.run(cli, [verb, id], timeout: Self.timeout)
    }
}
