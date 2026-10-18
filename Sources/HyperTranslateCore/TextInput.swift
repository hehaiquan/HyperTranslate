import Foundation

public struct TranslationInput: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case word, passage }
    public let text: String
    public let kind: Kind
    public static let maximumLength = 12_000

    /// 校验输入并区分单词与段落，保留段落内部换行。
    public init(_ source: String) throws {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InputError.empty }
        guard text.count <= Self.maximumLength else { throw InputError.tooLong }
        guard text.range(of: "[A-Za-z]", options: .regularExpression) != nil else {
            throw InputError.noEnglish
        }
        let word = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'‘’“”()[]{}.,!?;:«»"))
        if word.range(of: "^[A-Za-z]+(?:['’\\-][A-Za-z]+)*$", options: .regularExpression) != nil {
            self.text = word.replacingOccurrences(of: "’", with: "'")
            kind = .word
        } else {
            self.text = text
            kind = .passage
        }
    }
}

public enum InputError: LocalizedError {
    case empty, noEnglish, tooLong
    public var errorDescription: String? {
        switch self {
        case .empty: return "请先选择、输入或复制英文。"
        case .noEnglish: return "没有找到英文，请选择英文单词或句子。"
        case .tooLong: return "一次最多翻译 12,000 个字符，请缩小选区。"
        }
    }
}

public struct ParagraphLayout: Sendable {
    private let parts: [String]
    public let texts: [String]

    /// 按换行拆分原文，记录空行和纯空白行以便恢复段落布局。
    public init(_ text: String) {
        parts = text.components(separatedBy: "\n")
        texts = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 将逐行译文放回原位置；数量不符时报告错误，避免丢段。
    public func restoring(_ translations: [String]) throws -> String {
        guard translations.count == texts.count else { throw TranslationFailure.incomplete }
        var index = 0
        return parts.map { part in
            guard !part.trimmingCharacters(in: .whitespaces).isEmpty else { return part }
            defer { index += 1 }
            return translations[index]
        }.joined(separator: "\n")
    }
}

public enum TranslationFailure: LocalizedError {
    case incomplete, unavailable, modelsNotReady
    public var errorDescription: String? {
        switch self {
        case .incomplete: return "系统返回的译文不完整，请重试。"
        case .unavailable: return "系统暂不支持英文到简体中文的翻译。"
        case .modelsNotReady: return "语言包尚未安装完成，请稍后在「权限与语言包」检查状态。"
        }
    }
}

public struct RequestGeneration: Sendable {
    private var current = UUID()
    /// 初始化独立查询代次。
    public init() {}

    /// 生成新的查询标识，让此前异步任务的结果失效。
    @discardableResult public mutating func advance() -> UUID {
        current = UUID()
        return current
    }

    /// 检查异步结果是否仍属于当前查询。
    public func contains(_ identifier: UUID) -> Bool { current == identifier }
}
