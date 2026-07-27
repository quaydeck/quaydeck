import XCTest
@testable import QuaydeckCore

final class ProjectResolverTests: XCTestCase {

    private func resolver(_ fileSystem: FileSystemProbe = DevMachine.fileSystem,
                          userRoots: [String] = []) -> ProjectResolver {
        ProjectResolver(fileSystem: fileSystem, home: DevMachine.home, userRoots: userRoots)
    }

    // MARK: - The portability fix

    /// The whole point of the rewrite: a project is found by its manifest, not by
    /// living in one particular person's folder layout.
    func testFindsProjectsAnywhereOnDisk() {
        let fileSystem = StubFileSystem(
            directories: ["/opt/work/thing", "/srv/www/api"],
            files: ["/opt/work/thing/package.json": #"{"name":"thing"}"#,
                    "/srv/www/api/go.mod": "module api\n"]
        )
        XCTAssertEqual(resolver(fileSystem).resolve(cwd: "/opt/work/thing", args: "")?.name, "thing")
        XCTAssertEqual(resolver(fileSystem).resolve(cwd: "/srv/www/api", args: "")?.name, "api")
    }

    func testWalksUpFromASubdirectoryToTheProjectRoot() {
        let project = resolver().resolve(cwd: "/Users/dev/code/shop/src/pages", args: "")
        XCTAssertEqual(project?.path, "/Users/dev/code/shop")
    }

    func testStopsAtHomeRatherThanClimbingOut() {
        XCTAssertNil(resolver().resolve(cwd: "/Users/dev", args: ""))
        XCTAssertNil(resolver().resolve(cwd: "/", args: ""))
    }

    // MARK: - Naming

    func testPrefersTheManifestNameAndStripsTheScope() {
        XCTAssertEqual(resolver().resolve(cwd: "/Users/dev/code/acme-site", args: "")?.name, "site")
    }

    func testFallsBackToTheDirectoryNameWithoutAManifestName() {
        XCTAssertEqual(resolver().resolve(cwd: "/Users/dev/code/notes", args: "")?.name, "notes")
    }

    // MARK: - Path handling

    /// A project directory legitimately named "my.site" must not be mistaken for a
    /// file and truncated to its parent.
    func testKeepsDirectoryNamesContainingDots() {
        let fileSystem = StubFileSystem(
            directories: ["/Users/dev/code/my.site"],
            files: ["/Users/dev/code/my.site/package.json": #"{"name":"my.site"}"#]
        )
        let project = resolver(fileSystem).resolve(cwd: "/Users/dev/code/my.site", args: "")
        XCTAssertEqual(project?.path, "/Users/dev/code/my.site")
    }

    /// A config file passed on the command line should start its walk at its directory.
    func testDropsATrailingFilenameBeforeWalking() {
        let project = resolver().resolve(cwd: "/", args: "node /Users/dev/code/shop/astro.config.mjs")
        XCTAssertEqual(project?.path, "/Users/dev/code/shop")
    }

    func testIgnoresSystemBinariesInTheArgumentVector() {
        // The interpreter path must never be mistaken for the project.
        let project = resolver().resolve(cwd: "/Users/dev/code/shop",
                                         args: "/opt/homebrew/bin/node /Users/dev/code/shop/server.js")
        XCTAssertEqual(project?.path, "/Users/dev/code/shop")
    }

    // MARK: - Monorepos

    /// In a monorepo the individual app is the useful identity, while the repository
    /// is what git questions should be asked about.
    func testPrefersTheInnerPackageButRecordsTheRepositoryRoot() {
        let fileSystem = StubFileSystem(
            directories: ["/Users/dev/code/mono", "/Users/dev/code/mono/.git",
                          "/Users/dev/code/mono/apps", "/Users/dev/code/mono/apps/web"],
            files: ["/Users/dev/code/mono/package.json": #"{"name":"mono"}"#,
                    "/Users/dev/code/mono/apps/web/package.json": #"{"name":"web"}"#]
        )
        let project = resolver(fileSystem).resolve(cwd: "/Users/dev/code/mono/apps/web", args: "")
        XCTAssertEqual(project?.name, "web")
        XCTAssertEqual(project?.path, "/Users/dev/code/mono/apps/web")
        XCTAssertEqual(project?.gitRoot, "/Users/dev/code/mono")
    }

    // MARK: - User-configured roots

    /// For anyone whose projects carry no manifest at all, a configured root still
    /// produces a sensible name instead of a bare path.
    func testUsesAConfiguredRootWhenNoManifestExists() {
        let fileSystem = StubFileSystem(directories: ["/Users/dev/Sites/plain-html"])
        let project = resolver(fileSystem, userRoots: ["/Users/dev/Sites"])
            .resolve(cwd: "/Users/dev/Sites/plain-html/assets", args: "")
        XCTAssertEqual(project?.name, "plain-html")
        XCTAssertEqual(project?.path, "/Users/dev/Sites/plain-html")
    }

    func testAManifestStillWinsOverAConfiguredRoot() {
        let project = resolver(userRoots: ["/Users/dev/code"])
            .resolve(cwd: "/Users/dev/code/shop/src", args: "")
        XCTAssertEqual(project?.path, "/Users/dev/code/shop")
    }
}
