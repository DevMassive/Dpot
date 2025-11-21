import XCTest
@testable import Dpot

final class DpotTests: XCTestCase {
    func testFuzzyMatcherPrefersTightMatches() throws {
        let tight = FuzzyMatcher.matchScore(query: "saf", candidate: "Safari")
        let loose = FuzzyMatcher.matchScore(query: "saf", candidate: "Seafood Finder")

        XCTAssertNotNil(tight)
        XCTAssertNotNil(loose)
        XCTAssertGreaterThan(tight!, loose!)
    }

    func testFuzzyMatcherRejectsMissingChars() throws {
        XCTAssertNil(FuzzyMatcher.matchScore(query: "xyz", candidate: "Safari"))
    }

    func testAppIndexFindsAppsInInjectedRoots() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApp(at: root.appendingPathComponent("Foo.app"))
        try makeApp(at: root.appendingPathComponent("Bar.app"))

        let index = AppIndex(roots: [root])
        let apps = index.load()

        XCTAssertEqual(apps.map(\.name).sorted(), ["Bar", "Foo"])
        let expectedPaths: Set<String> = [
            root.appendingPathComponent("Foo.app").standardizedFileURL.path,
            root.appendingPathComponent("Bar.app").standardizedFileURL.path
        ]
        let actualPaths = Set(apps.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        XCTAssertEqual(actualPaths, expectedPaths)
    }

    @MainActor
    func testEnterLaunchesSelectedApp() {
        let controller = LauncherController(appIndex: AppIndex(roots: []))
        let app = AppItem(name: "Foo", path: "/tmp/Foo.app")

        var launched: AppItem?
        controller.onLaunch = { launched = $0 }
        controller.setAppsForTesting([app])

        controller.simulateCommand(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(launched?.name, "Foo")
    }

    @MainActor
    func testArrowKeysChangeSelection() {
        let controller = LauncherController(appIndex: AppIndex(roots: []))
        let a = AppItem(name: "A", path: "/tmp/A.app")
        let b = AppItem(name: "B", path: "/tmp/B.app")

        controller.setAppsForTesting([a, b])
        XCTAssertEqual(controller.selectedAppForTesting?.name, "A")

        controller.simulateCommand(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(controller.selectedAppForTesting?.name, "B")

        controller.simulateCommand(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(controller.selectedAppForTesting?.name, "A")
    }

    // MARK: - Helpers

    private func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApp(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
