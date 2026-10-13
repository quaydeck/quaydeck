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
        ("figma_agent", "Figma font helper"),
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

    /// Tooling an agent runs for itself rather than for you: MCP servers fetched by
    /// `npx`, helpers inside the agents' own data directories.
    static let agentToolingMarkers = ["/.npm/_npx/", "/.codex/", "/.claude/", "/.cache/", "/node_modules/.bin/mcp"]

    /// A runtime serving files from a folder with no project manifest: Codex and Claude
    /// previews (`python3 -m http.server` in a chat's outputs folder), or a quick static
    /// server of your own. Classified as `.system` until something vouches for it.
    ///
    /// `startedByAgent` is that something for agent previews; a plain `http.server`
    /// vouches for itself. Without either, a runtime in a folder could just as well be
    /// an app's helper, which is why this is not the default.
    public func isProjectlessServer(command: String, args: String, cwd: String,
                                    startedByAgent: Bool) -> Bool {
        let loweredCommand = command.lowercased()
        let loweredArgs = args.lowercased()
        guard Self.interpreters.contains(loweredCommand)
                || loweredArgs.contains("npx ") || loweredArgs.contains("bunx ") else { return false }
        if args.contains("/Applications/") || args.contains("/System/Library/") { return false }
        if Self.agentToolingMarkers.contains(where: args.contains) { return false }
        guard cwd != "/", cwd != home, !cwd.isEmpty else { return false }
        return startedByAgent || loweredArgs.contains("http.server") || loweredArgs.contains("simplehttpserver")
    }

    /// Whether a runtime is worth checking for agent markers at all. Keeps the parent
    /// walk, which forks `ps`, off the many listeners that can never be dev servers.
    public func mightBeProjectlessServer(command: String, args: String, cwd: String) -> Bool {
        isProjectlessServer(command: command, args: args, cwd: cwd, startedByAgent: true)
    }
}
