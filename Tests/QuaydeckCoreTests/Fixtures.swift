import Foundation
import XCTest
@testable import QuaydeckCore

/// Loads a recorded command output from the Fixtures directory.
///
/// Fixtures are real `lsof` and `ps` output. When a bug report arrives as a paste of
/// someone's terminal, it becomes a file here and a failing test, rather than a guess.
enum Fixture {
    static func text(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        else {
            XCTFail("Missing fixture: \(name)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// The imaginary machine the dev-server fixtures describe.
enum DevMachine {
    static let home = "/Users/dev"

    static let fileSystem = StubFileSystem(
        directories: [
            "/Users/dev/code",
            "/Users/dev/code/acme-site",
            "/Users/dev/code/acme-site/.git",
            "/Users/dev/code/shop",
            "/Users/dev/code/shop/.git",
            "/Users/dev/code/notes",
            "/Users/dev/code/rails-app",
            "/Users/dev/code/rails-app/.git",
            "/tmp",
            "/tmp/.hidden",
        ],
        files: [
            "/Users/dev/code/acme-site/package.json":
                #"{"name":"@acme/site","devDependencies":{"vite":"^5.0.0"}}"#,
            "/Users/dev/code/shop/package.json":
                #"{"name":"shop","dependencies":{"astro":"^4.0.0"}}"#,
            "/Users/dev/code/notes/pyproject.toml": "[project]\nname = \"notes\"\n",
            "/Users/dev/code/rails-app/Gemfile": "source 'https://rubygems.org'\n",
        ]
    )

    /// A runner wired to the dev-server fixtures. `psAll` defaults to empty so busy
    /// process detection stays out of the way unless a test asks for it.
    static func runner(listeners: String, processes: String, cwds: String,
                       psAll: String = "", git: String = "") -> FixtureRunner {
        FixtureRunner([
            // Most specific first: the cwd query also contains "-p".
            (exe: "lsof", fragment: "-d cwd", output: cwds),
            (exe: "lsof", fragment: "-iTCP", output: listeners),
            (exe: "ps", fragment: "-Ao", output: psAll),
            (exe: "ps", fragment: "-p", output: processes),
            (exe: "git", fragment: "", output: git),
        ])
    }

    static func inventory(listeners: String, processes: String, cwds: String,
                          psAll: String = "") -> PortInventory {
        PortInventory(
            runner: runner(listeners: listeners, processes: processes, cwds: cwds, psAll: psAll),
            fileSystem: fileSystem,
            home: home
        )
    }
}
