import XCTest
@testable import Dpot

final class FeatureTests: XCTestCase {
    
    // 1. 全角英数字入力の場合は半角も検索してほしい。
    func testFullWidthSearch() {
        let candidate = "Safari"
        // Full-width 'Ｓ' 'ａ' 'ｆ'
        let fullWidthQuery = "Ｓａｆ"
        
        let score = FuzzyMatcher.matchScore(query: fullWidthQuery, candidate: candidate)
        XCTAssertNotNil(score, "Should match candidate even with full-width query")
    }

    // 2. 初期表示は起動数順で、同じ起動数の場合はアルファベット順で。
    @MainActor
    func testInitialDisplayOrdering() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        
        let aPath = root.appendingPathComponent("Alpha.app").standardizedFileURL.path
        let bPath = root.appendingPathComponent("Beta.app").standardizedFileURL.path
        let cPath = root.appendingPathComponent("Charlie.app").standardizedFileURL.path
        
        try makeApp(at: URL(fileURLWithPath: aPath))
        try makeApp(at: URL(fileURLWithPath: bPath))
        try makeApp(at: URL(fileURLWithPath: cPath))
        
        let usageURL = root.appendingPathComponent("usage.json")
        let appIndex = AppIndex(roots: [root], usageURL: usageURL)
        
        // Bump usage
        appIndex.bumpUsage(for: bPath) // B has 1
        appIndex.bumpUsage(for: bPath) // B has 2
        appIndex.bumpUsage(for: cPath) // C has 1
        // A has 0
        
        // Wait for usage to be saved (it's async on a queue)
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let controller = LauncherController(appIndex: appIndex)
        
        // Initially it might be empty because refreshAsync is async
        // We can wait for it.
        let exp = expectation(description: "Refresh")
        appIndex.refreshAsync(collectMetrics: false) { _, _ in
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 2.0)
        
        // Now force controller to reload from index
        controller.show()
        
        // Expected order: Beta (2), Charlie (1), Alpha (0)
        XCTAssertEqual(controller.appAtRowForTesting(0)?.name, "Beta")
        XCTAssertEqual(controller.appAtRowForTesting(1)?.name, "Charlie")
        XCTAssertEqual(controller.appAtRowForTesting(2)?.name, "Alpha")
    }

    // MARK: - Helpers duplicated from DpotTests for simplicity
    private func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApp(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
