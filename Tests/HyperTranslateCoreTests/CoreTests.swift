import Foundation
@testable import HyperTranslateCore
import XCTest

final class CoreTests: XCTestCase {
    /// 验证英文词、内部撇号、连字符及外部标点的分类。
    func testWordClassification() throws {
        for word in ["hello", "Hello", "can't", "well-known", "don’t", "'hello'", "“hello,”"] {
            XCTAssertEqual(try TranslationInput(word).kind, .word, word)
        }
        XCTAssertEqual(try TranslationInput("don’t").text, "don't")
        XCTAssertEqual(try TranslationInput("  hello. ").text, "hello")
    }

    /// 多词文本保持换行，避免段落被压缩成一行。
    func testPassageClassification() throws {
        let input = try TranslationInput("First sentence.\r\n\r\nSecond sentence.")
        XCTAssertEqual(input.kind, .passage)
        XCTAssertEqual(input.text, "First sentence.\n\nSecond sentence.")
        XCTAssertEqual(try TranslationInput("look up").kind, .passage)
        XCTAssertEqual(try TranslationInput("hello world!").kind, .passage)
    }

    /// 拒绝空内容、无英文内容和超限输入，不静默截断。
    func testInvalidInput() {
        for source in ["", " \n", "12345", "你好", String(repeating: "a", count: 12_001)] {
            XCTAssertThrowsError(try TranslationInput(source))
        }
        XCTAssertNoThrow(try TranslationInput(String(repeating: "a", count: 12_000)))
    }

    /// 恢复空行及纯空白行，并拒绝不完整译文。
    func testParagraphRestoration() throws {
        let layout = ParagraphLayout("Hello.\n\n  \nGoodbye.\n")
        XCTAssertEqual(layout.texts, ["Hello.", "Goodbye."])
        XCTAssertEqual(try layout.restoring(["你好。", "再见。"]), "你好。\n\n  \n再见。\n")
        XCTAssertThrowsError(try layout.restoring(["你好。"]))
    }

    /// 使用真实内置词库验证数量、词义、音标、大小写和缺失字段。
    func testBundledDictionary() async throws {
        let store = try DictionaryStore()
        let count = try await store.entryCount()
        XCTAssertEqual(count, 770_611)
        let hello = try await store.lookup("HELLO")
        XCTAssertEqual(hello?.word.lowercased(), "hello")
        XCTAssertFalse(hello?.phonetic.isEmpty ?? true)
        XCTAssertTrue(hello?.chineseDefinition.contains("喂") ?? false)
        let noPhonetic = try await store.lookup("well-known")
        XCTAssertEqual(noPhonetic?.phonetic, "")
        XCTAssertFalse(noPhonetic?.chineseDefinition.isEmpty ?? true)
        let unknown = try await store.lookup("hypertranslateunlistedwordzzzz")
        XCTAssertNil(unknown)
    }

    /// 验证不规则词形，同时保留 saw 和 running 自身的词义与读音。
    func testInflectionsPreserveOriginalMeanings() async throws {
        let store = try DictionaryStore()
        for (word, lemma) in [("gave", "give"), ("taken", "take"), ("teeth", "tooth"), ("books", "book")] {
            let entry = try await store.lookup(word)
            XCTAssertEqual(entry?.word, word)
            XCTAssertEqual(entry?.lemma?.word, lemma)
            XCTAssertFalse(entry?.lemma?.chineseDefinition.isEmpty ?? true)
        }
        let saw = try await store.lookup("saw")
        XCTAssertTrue(saw?.chineseDefinition.contains("锯子") ?? false)
        XCTAssertEqual(saw?.lemma?.word, "see")
        XCTAssertEqual(saw?.phonetic, "sɒ:")
        let running = try await store.lookup("running")
        XCTAssertTrue(running?.chineseDefinition.contains("赛跑") ?? false)
        XCTAssertEqual(running?.lemma?.word, "run")
    }

    /// 查词使用绑定参数，带 SQL 文本的输入不会改变查询含义。
    func testDictionarySQLInput() async throws {
        let store = try DictionaryStore()
        let entry = try await store.lookup("hello' OR 1=1 --")
        XCTAssertNil(entry)
        let cant = try await store.lookup("can’t")
        XCTAssertEqual(cant?.word, "can't")
    }

    /// 旧请求在新请求之后完成时，不允许覆盖新结果，即使旧任务未响应取消。
    @MainActor func testLateAsyncResultCannotOverwriteLatest() async throws {
        let probe = GenerationProbe()
        let old = probe.submit("旧结果", delay: .milliseconds(70))
        let latest = probe.submit("新结果", delay: .milliseconds(5))
        await latest.value
        await old.value
        XCTAssertEqual(probe.result, "新结果")
    }

    /// 关闭浮窗后使尚未结束的查询代次失效。
    func testInvalidatedGenerationRejectsLateResponse() {
        var generation = RequestGeneration()
        let identifier = generation.advance()
        generation.advance()
        XCTAssertFalse(generation.contains(identifier))
    }
}

@MainActor private final class GenerationProbe {
    private var generation = RequestGeneration()
    var result = ""

    /// 模拟不能及时取消的异步服务，使用与界面相同的代次保护。
    func submit(_ value: String, delay: Duration) -> Task<Void, Never> {
        let identifier = generation.advance()
        return Task {
            try? await Task.sleep(for: delay)
            if generation.contains(identifier) { result = value }
        }
    }
}
