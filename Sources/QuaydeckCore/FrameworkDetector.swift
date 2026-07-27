import Foundation

/// Works out what a dev server is actually running, so a row can say "Astro" rather
/// than "node".
public struct FrameworkDetector: Sendable {
    private let fileSystem: FileSystemProbe

    public init(fileSystem: FileSystemProbe = RealFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// Ordered: the first match wins, so more specific needles come first.
    /// "next" before "node", "uvicorn" before "python".
    static let argumentSignatures: [(needle: String, label: String)] = [
        ("astro", "Astro"),
        ("vite", "Vite"),
        ("next", "Next.js"),
        ("nuxt", "Nuxt"),
        ("remix", "Remix"),
        ("svelte", "SvelteKit"),
        ("vercel dev", "Vercel"),
        ("wrangler", "Cloudflare"),
        ("react-scripts", "React"),
        ("webpack", "Webpack"),
        ("storybook", "Storybook"),
        ("expo", "Expo"),
        ("rails", "Rails"),
        ("puma", "Rails"),
        ("flask", "Flask"),
        ("django", "Django"),
        ("uvicorn", "FastAPI"),
        ("gunicorn", "Python"),
        ("http.server", "Python"),
        ("hugo", "Hugo"),
        ("jekyll", "Jekyll"),
        ("ollama", "Ollama"),
        ("php", "PHP"),
    ]

    static let dependencySignatures: [(dependency: String, label: String)] = [
        ("astro", "Astro"),
        ("next", "Next.js"),
        ("nuxt", "Nuxt"),
        ("@remix-run/react", "Remix"),
        ("@sveltejs/kit", "SvelteKit"),
        ("vite", "Vite"),
        ("react", "React"),
    ]

    public func detect(args: String, command: String, projectPath: String?) -> String? {
        let lowered = args.lowercased()
        for signature in Self.argumentSignatures where lowered.contains(signature.needle) {
            return signature.label
        }

        if let projectPath, let dependencies = packageDependencies(at: projectPath) {
            for signature in Self.dependencySignatures where dependencies.contains(signature.dependency) {
                return signature.label
            }
        }

        return runtimeName(command)
    }

    /// Last resort: name the runtime rather than the framework.
    private func runtimeName(_ command: String) -> String? {
        let lowered = command.lowercased()
        let runtimes: [(String, String)] = [
            ("python", "Python"), ("node", "Node"), ("deno", "Deno"), ("bun", "Bun"),
            ("ruby", "Ruby"), ("php", "PHP"), ("go", "Go"), ("java", "Java"),
            ("dotnet", ".NET"),
        ]
        for (needle, label) in runtimes where lowered.contains(needle) { return label }
        return nil
    }

    private func packageDependencies(at path: String) -> Set<String>? {
        guard let data = fileSystem.contents(at: path + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var keys = Set<String>()
        for field in ["dependencies", "devDependencies"] {
            if let block = json[field] as? [String: Any] { keys.formUnion(block.keys) }
        }
        return keys
    }
}
