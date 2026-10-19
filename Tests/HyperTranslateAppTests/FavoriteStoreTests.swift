import Foundation
@testable import HyperTranslate
import XCTest

@MainActor
final class FavoriteStoreTests: XCTestCase {
    /// 重启存储后仍保留原选变形词、释义和音标；删除也必须持久化。
    func testFavoritesSurviveReloadAndRemoval() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Favorites.json")
        let store = FavoriteStore(fileURL: url)
        XCTAssertNil(store.errorMessage)
        store.add(word: "gave", phonetic: "ɡeɪv", definition: "give 的过去式")
        let reloaded = FavoriteStore(fileURL: url)
        XCTAssertEqual(reloaded.words, store.words)
        XCTAssertEqual(reloaded.words.first?.word, "gave")
        XCTAssertEqual(reloaded.words.first?.phonetic, "ɡeɪv")
        XCTAssertEqual(reloaded.words.first?.definition, "give 的过去式")
        reloaded.remove("GAVE")
        XCTAssertTrue(FavoriteStore(fileURL: url).words.isEmpty)
    }

    /// 不同大小写及直弯引号的同一单词不能重复收藏。
    func testNormalizedWordIsNotDuplicated() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteStore(fileURL: directory.appendingPathComponent("Favorites.json"))
        store.add(word: "Don't", phonetic: "", definition: "不要")
        store.add(word: "DON’T", phonetic: "", definition: "别")
        XCTAssertEqual(store.words.count, 1)
        XCTAssertTrue(store.contains("don’t"))
        XCTAssertEqual(store.words.first?.definition, "不要")
        store.remove("DON’T")
        XCTAssertTrue(store.words.isEmpty)
    }

    /// 段落和没有释义的输入不会进入单词本；标点按既有输入规则处理。
    func testOnlyWordsWithDefinitionsCanBeSaved() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteStore(fileURL: directory.appendingPathComponent("Favorites.json"))
        store.add(word: "Hello world.", phonetic: "", definition: "你好，世界")
        store.add(word: "hello", phonetic: "", definition: " \n")
        XCTAssertTrue(store.words.isEmpty)
        store.add(word: "hello!", phonetic: "", definition: "你好")
        XCTAssertEqual(store.words.first?.word, "hello")
    }

    /// 写入路径不可用时显示失败，不能把未落盘的收藏伪装成成功。
    func testWriteFailureKeepsPreviousState() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Favorites.json")
        let store = FavoriteStore(fileURL: url)
        store.add(word: "hello", phonetic: "", definition: "你好")
        let previous = store.words
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        store.remove("hello")
        XCTAssertEqual(store.words, previous)
        XCTAssertNotNil(store.errorMessage)
        store.add(word: "world", phonetic: "", definition: "世界")
        XCTAssertEqual(store.words, previous)
        try FileManager.default.removeItem(at: directory)
        store.add(word: "world", phonetic: "", definition: "世界")
        XCTAssertEqual(store.words.count, 2)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(FavoriteStore(fileURL: url).words, store.words)
    }

    /// 收藏文件无法解析时保留原文件，后续收藏和删除都不能覆盖它。
    func testCorruptFileIsPreserved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Favorites.json")
        let original = Data("invalid json".utf8)
        try original.write(to: url)
        let store = FavoriteStore(fileURL: url)
        XCTAssertNotNil(store.errorMessage)
        store.add(word: "hello", phonetic: "", definition: "你好")
        store.remove("hello")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(store.words.isEmpty)
    }

    /// 每项测试使用独立临时目录，不读取或写入用户真实收藏。
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HyperTranslateTests-" + UUID().uuidString)
    }
}
