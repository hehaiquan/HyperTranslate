import Foundation
import SQLite3

public struct DictionaryEntry: Equatable, Sendable {
    public let word: String
    public let phonetic: String
    public let englishDefinition: String
    public let chineseDefinition: String
    public let partOfSpeech: String
    public var lemma: DictionaryLemma? = nil
}

public struct DictionaryLemma: Equatable, Sendable {
    public let word: String
    public let chineseDefinition: String
}

public actor DictionaryStore {
    private var database: OpaquePointer?

    /// 打开随应用发布的只读词库，也允许测试指定数据库路径。
    public init(url: URL? = nil) throws {
        guard let location = url ?? Bundle.module.url(forResource: "Dictionary", withExtension: "sqlite") else {
            throw StoreError.missing
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(location.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            throw StoreError.unreadable
        }
        database = handle
    }

    deinit { sqlite3_close(database) }

    /// 优先匹配原词，再查询可靠的词形映射；不通过猜测词尾生成释义。
    public func lookup(_ word: String) throws -> DictionaryEntry? {
        let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
        var exact = try entry(key)
        let lemmas = try lemmaCandidates(key)
        // 保留 saw 等变形词自身的词义及音标，另外补充原形解释。
        for lemma in lemmas {
            guard let canonical = try entry(lemma), !canonical.chineseDefinition.isEmpty else { continue }
            if exact != nil {
                exact?.lemma = DictionaryLemma(word: canonical.word, chineseDefinition: canonical.chineseDefinition)
                return exact
            }
            return canonical
        }
        return exact
    }

    /// 读取词库元数据，供诊断与验收显示真实词条数量。
    public func entryCount() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT count(*) FROM entries", -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.unreadable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.unreadable }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// 用绑定参数读取词条，避免输入中的引号影响 SQL。
    private func entry(_ key: String) throws -> DictionaryEntry? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT word, phonetic, definition, translation, pos FROM entries WHERE word = ? COLLATE NOCASE LIMIT 1",
            -1, &statement, nil) == SQLITE_OK else { throw StoreError.unreadable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw StoreError.unreadable }
        return DictionaryEntry(word: string(statement, 0), phonetic: string(statement, 1),
                               englishDefinition: string(statement, 2), chineseDefinition: string(statement, 3),
                               partOfSpeech: string(statement, 4))
    }

    /// 读取固定词形表中的原形候选，优先采用词条自身声明的映射。
    private func lemmaCandidates(_ key: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT lemma FROM forms WHERE form = ? AND lemma <> ? ORDER BY priority, lemma LIMIT 8",
            -1, &statement, nil) == SQLITE_OK else { throw StoreError.unreadable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, key, -1, transient)
        var values: [String] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            values.append(string(statement, 0))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw StoreError.unreadable }
        return values
    }

    /// 安全转换 SQLite 的 UTF-8 列值，空值按空字符串返回。
    private func string(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
}

public enum StoreError: LocalizedError {
    case missing, unreadable
    public var errorDescription: String? {
        switch self {
        case .missing: return "未找到离线词库，请重新运行打包脚本。"
        case .unreadable: return "离线词库无法读取，请重新安装应用。"
        }
    }
}
