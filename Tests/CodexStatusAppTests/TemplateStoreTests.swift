import XCTest
@testable import CodexStatusApp

final class TemplateStoreTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("templates-\(UUID().uuidString)")
    }

    func testSeedsDefaultsOnceAndNeverOverwritesUserEdits() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TemplateStore(directory: directory)
        XCTAssertTrue(store.seedIfNeeded())
        XCTAssertEqual(store.load().count, 18)
        try "## 我的\n自定义内容".write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.seedIfNeeded())
        XCTAssertEqual(store.load().map(\.title), ["我的"])
    }

    func testAppendWritesToFileAndSurvivesReload() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TemplateStore(directory: directory)
        XCTAssertTrue(store.append(title: "我的新模板", body: "内容"))
        XCTAssertTrue(store.load().contains { $0.title == "我的新模板" && !$0.isMore })
        XCTAssertFalse(store.append(title: "", body: "内容"))
    }

    func testMissingOrOversizedFileLoadsNothing() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TemplateStore(directory: directory)
        XCTAssertTrue(store.load().isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 600 * 1024).write(to: store.fileURL)
        XCTAssertTrue(store.load().isEmpty)
    }
}
