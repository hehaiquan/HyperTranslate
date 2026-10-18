import Foundation

public struct UsageExample: Codable, Equatable, Sendable, Identifiable {
    public var id: String { english }
    public let english: String
    public var chinese: String?
    public let sourceURLs: [String]
    public let licenseName: String?
    public let licenseURL: String?

    /// 构造带来源的例句，中文译文由本地翻译服务补充。
    public init(english: String, chinese: String? = nil, sourceURLs: [String] = [],
                licenseName: String? = nil, licenseURL: String? = nil) {
        self.english = english
        self.chinese = chinese
        self.sourceURLs = sourceURLs
        self.licenseName = licenseName
        self.licenseURL = licenseURL
    }
}

public actor ExampleService {
    private let session: URLSession
    private let cacheDirectory: URL
    private let expiry: TimeInterval = 30 * 24 * 60 * 60

    /// 设置网络超时和仅保存例句的独立缓存目录。
    public init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            self.session = URLSession(configuration: configuration)
        }
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hypertranslate.mac/Examples", isDirectory: true)
    }

    /// 获取缓存或公开词典例句，仅向服务发送单词，不发送选中段落。
    public func examples(for word: String) async throws -> [UsageExample] {
        try Task.checkCancellation()
        let key = try cacheKey(word)
        if let cached = load(key), Date().timeIntervalSince(cached.createdAt) < expiry { return cached.examples }
        let endpoint = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/")!
            .appendingPathComponent(key)
        do {
            let (data, response) = try await session.data(from: endpoint)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ExampleError.network }
            if http.statusCode == 404 {
                try? save([], for: key)
                return []
            }
            guard http.statusCode == 200, data.count < 2_000_000 else { throw ExampleError.network }
            let examples = try Self.decode(data)
            try? save(examples, for: key)
            return examples
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let cached = load(key), !cached.examples.isEmpty { return cached.examples }
            throw error
        }
    }

    /// 保存已补充中文的例句；不保存用户查询的段落或历史记录。
    public func save(_ examples: [UsageExample], for word: String) throws {
        let key = try cacheKey(word)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(CachedExamples(createdAt: Date(), examples: examples))
        try data.write(to: cacheDirectory.appendingPathComponent(key + ".json"), options: .atomic)
    }

    /// 解析接口中的可选例句、来源和许可，去重并限制为两条。
    public static func decode(_ data: Data) throws -> [UsageExample] {
        let entries = try JSONDecoder().decode([APIEntry].self, from: data)
        var result: [UsageExample] = []
        var seen = Set<String>()
        for entry in entries {
            for meaning in entry.meanings {
                for definition in meaning.definitions {
                    guard let sentence = definition.example?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !sentence.isEmpty, sentence.count <= 1_000,
                          seen.insert(sentence.lowercased()).inserted else { continue }
                    result.append(UsageExample(english: sentence, sourceURLs: entry.sourceUrls ?? [],
                                               licenseName: entry.license?.name, licenseURL: entry.license?.url))
                    if result.count == 2 { return result }
                }
            }
        }
        return result
    }

    /// 校验缓存键，阻止路径字符和句子进入联网查词入口。
    private func cacheKey(_ word: String) throws -> String {
        let input = try TranslationInput(word)
        guard input.kind == .word, input.text.count <= 100 else { throw ExampleError.invalidWord }
        return input.text.lowercased()
    }

    /// 读取缓存；损坏文件不妨碍重新请求。
    private func load(_ key: String) -> CachedExamples? {
        guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent(key + ".json")) else { return nil }
        return try? JSONDecoder().decode(CachedExamples.self, from: data)
    }

    private struct CachedExamples: Codable { let createdAt: Date; let examples: [UsageExample] }
    private struct APIEntry: Decodable {
        let meanings: [Meaning]
        let sourceUrls: [String]?
        let license: License?
        struct Meaning: Decodable { let definitions: [Definition] }
        struct Definition: Decodable { let example: String? }
        struct License: Decodable { let name: String?; let url: String? }
    }
}

public enum ExampleError: LocalizedError {
    case network, invalidWord
    public var errorDescription: String? {
        switch self {
        case .network: return "例句服务暂不可用，本地查词和翻译仍可使用。"
        case .invalidWord: return "该内容无法作为单词查询例句。"
        }
    }
}
