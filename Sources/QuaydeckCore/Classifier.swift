import Foundation

/// Decides what each listener is: a dev server you started, local infrastructure,
/// ordinary macOS noise, or something that deserves a second look.
///
/// This is the part of Quaydeck most likely to be wrong on a machine that is not the
/// author's, which is exactly why it takes all its input as plain values and is
/// covered by fixture tests.
public struct Classifier: Sendable {

    /// Binary locations we consider legitimate. Anything listening from outside these
    /// is flagged, not because it is malware, but because it is worth knowing about.
    static let trustedPrefixes = [
        "/Applications/",
        "/System/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/opt/homebrew/",
        "/opt/local/",
        "/usr/local/",
        "/Library/",
        "/private/var/db/",
        "/nix/store/",
    ]

    /// Trusted locations inside the user's home directory.
    ///
    /// `~/Library/Developer` matters: every app running in an iOS, tvOS or watchOS
    /// simulator listens from there, and without this an iOS developer would see their
    /// own simulator reported as an unrecognised listener on every scan.
    static let homeTrustedPrefixes = [
        "/Library/Developer/",
        "/Applications/",
        "/.rbenv/",
        "/.nvm/",
        "/.pyenv/",
        "/.asdf/",
        "/.cargo/",
        "/.local/bin/",
        "/go/bin/",
    ]

    /// Runtimes that, when launched from a project directory, mean "dev server".
    static let interpreters: Set<String> = [
        "node", "deno", "bun", "python", "python2", "python3", "ruby", "php", "php-fpm",
        "puma", "rails", "go", "cargo", "java", "dotnet", "uvicorn", "gunicorn", "elixir",
        "beam.smp", "erl", "dart", "flutter", "air", "watchexec",
    ]

    /// Local dev infrastructure, recognised by process name rather than port. Ports
    /// get reused constantly, so port-based recognition produces confident nonsense.
    static let infrastructure: [(needle: String, label: String)] = [
        ("postgres", "PostgreSQL"),
        ("postmaster", "PostgreSQL"),
        ("redis", "Redis"),
        ("mysqld", "MySQL"),
        ("mariadb", "MariaDB"),
        ("mongod", "MongoDB"),
        ("elasticsearch", "Elasticsearch"),
        ("opensearch", "OpenSearch"),
        ("memcached", "Memcached"),
        ("rabbitmq", "RabbitMQ"),
        ("minio", "MinIO"),
        ("mailpit", "Mailpit"),
        ("mailhog", "MailHog"),
        ("clickhouse", "ClickHouse"),
        ("couchdb", "CouchDB"),
        ("supabase", "Supabase"),
        ("localstack", "LocalStack"),
        ("dynamodb", "DynamoDB Local"),
        ("docker", "Docker"),
        ("colima", "Colima"),
        ("orbstack", "OrbStack"),
    ]

    /// Friendly names for well-known macOS and third-party listeners, so the noise
    /// list reads as "AirPlay" rather than "ControlCenter".
    static let friendlyNames: [(needle: String, label: String)] = [
        ("controlce", "AirPlay / Control Center"),
        ("rapportd", "Continuity (AirDrop / Handoff)"),
        ("sharingd", "Sharing"),
        ("remoted", "Remote Device"),
        ("spotify", "Spotify"),
        ("raycast", "Raycast"),
        ("ollama", "Ollama (local model)"),
        ("chrome", "Chrome (remote debugging)"),
        ("firefox", "Firefox"),
        ("logioptio", "Logi Options+"),
        ("google drive", "Google Drive"),
        ("dropbox", "Dropbox"),
        ("syncthing", "Syncthing"),
        ("plex", "Plex"),
        ("steam", "Steam"),
        ("nginx", "nginx"),
        ("httpd", "Apache"),
        ("caddy", "Caddy"),
    ]

    /// Coding agents and editors worth crediting on a row, so you can tell which
    /// servers you started by hand and which something else started for you.
    static let agentSignatures: [(needle: String, label: String)] = [
        ("claude", "claude"),
        ("cursor", "cursor"),
        ("codex", "codex"),
        ("copilot", "copilot"),
        ("aider", "aider"),
    ]

    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    /// Classify one listener. `hasProject` is whether the resolver found a project
    /// directory for it, which is the difference between "a node dev server" and
    /// "some Electron app that happens to embed node".
    public func classify(command: String, args: String, hasProject: Bool) -> (kind: ListenerKind, label: String?) {
        let loweredCommand = command.lowercased()
        let loweredArgs = args.lowercased()

        // Infrastructure first: a Postgres launched from a project directory is still
        // Postgres, not a dev server.
        if let label = Self.infrastructure.first(where: {
            loweredCommand.contains($0.needle) || loweredArgs.contains($0.needle)
        })?.label {
            return (.service, label)
        }

        if isDevServer(command: loweredCommand, args: args, hasProject: hasProject) {
            return (.devServer, nil)
        }

        let friendly = Self.friendlyNames.first { loweredCommand.contains($0.needle) }?.label
        return (isTrusted(args: args, command: command) ? .system : .unrecognised, friendly)
    }

    /// A dev server is a runtime launched from a real project directory, and not a
    /// GUI application that merely bundles one.
    func isDevServer(command: String, args: String, hasProject: Bool) -> Bool {
        guard hasProject else { return false }

        let loweredArgs = args.lowercased()
        let isInterpreter = Self.interpreters.contains(command)
            || loweredArgs.contains("npm ") || loweredArgs.contains("pnpm ")
            || loweredArgs.contains("yarn ") || loweredArgs.contains("bunx ")
            || loweredArgs.contains("npx ")
        guard isInterpreter else { return false }

        // An installed app is never a dev server. Homebrew's python lives inside a
        // "Python.app" bundle, so we exclude real install locations rather than any
        // path containing ".app".
        if args.contains("/Applications/") || args.contains("/System/Library/") { return false }

        return true
    }

    func isTrusted(args: String, command: String) -> Bool {
        let executable = args.split(separator: " ").first.map(String.init) ?? command
        guard executable.hasPrefix("/") else {
            // No absolute path to judge. Treat it as ordinary rather than crying wolf.
            return true
        }
        if Self.trustedPrefixes.contains(where: { executable.hasPrefix($0) }) { return true }
        guard !home.isEmpty, executable.hasPrefix(home) else { return false }
        let relative = String(executable.dropFirst(home.count))
        return Self.homeTrustedPrefixes.contains { relative.hasPrefix($0) }
    }

    /// Which coding agent, if any, appears in a process's ancestry.
    public func agentName(inAncestry args: [String]) -> String? {
        for text in args {
            let lowered = text.lowercased()
            if let match = Self.agentSignatures.first(where: { lowered.contains($0.needle) }) {
                return match.label
            }
        }
        return nil
    }
}
