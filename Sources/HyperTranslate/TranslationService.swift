import Combine
import Foundation
import HyperTranslateCore
import Translation

@MainActor
final class TranslationService: ObservableObject {
    enum Availability { case checking, needsDownload, ready, unsupported }
    @Published var configuration: TranslationSession.Configuration?
    @Published private(set) var availability: Availability = .checking
    @Published private(set) var isWorking = false
    @Published private(set) var requestID: UUID?
    private var active: Job?
    private let source = Locale.Language(identifier: "en")
    private let target = Locale.Language(identifier: "zh-Hans")

    private struct Job {
        let id: UUID
        let texts: [String]
        let continuation: CheckedContinuation<[String], Error>
    }

    /// 检查传统本地翻译模型是否安装，不触发自动下载。
    func refreshAvailability() async {
        let checker: LanguageAvailability
        if #available(macOS 26.4, *) { checker = LanguageAvailability(preferredStrategy: .lowLatency) }
        else { checker = LanguageAvailability() }
        let status = await checker.status(from: source, to: target)
        switch status {
        case .installed: availability = .ready
        case .supported: availability = .needsDownload
        case .unsupported: availability = .unsupported
        @unknown default: availability = .unsupported
        }
    }

    /// 通过可见 SwiftUI 宿主请求系统下载授权并准备语言包。
    func prepare() async throws { _ = try await request([]) }

    /// 拆分并翻译段落，恢复每一段原有的空行。
    func translate(_ texts: [String]) async throws -> [String] {
        let layouts = texts.map(ParagraphLayout.init)
        let lines = layouts.flatMap(\.texts)
        guard !lines.isEmpty else { return texts }
        let translations = try await request(lines)
        var index = 0
        return try layouts.map { layout in
            let end = index + layout.texts.count
            guard end <= translations.count else { throw TranslationFailure.incomplete }
            defer { index = end }
            return try layout.restoring(Array(translations[index..<end]))
        }
    }

    /// 仅在 translationTask 回调生命周期内使用会话，不长期持有系统会话。
    func perform(using session: TranslationSession, requestID: UUID?) async {
        guard !Task.isCancelled, let job = active, job.id == requestID else { return }
        do {
            try Task.checkCancellation()
            try await session.prepareTranslation()
            try Task.checkCancellation()
            // 系统允许下载在后台继续，prepareTranslation 返回不等于模型已安装。
            await refreshAvailability()
            if !job.texts.isEmpty {
                guard availability == .ready else { throw TranslationFailure.modelsNotReady }
                if #available(macOS 26.0, *), await !session.isReady {
                    availability = .needsDownload
                    throw TranslationFailure.modelsNotReady
                }
            }
            let requests = job.texts.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            var translated: [String] = []
            if !requests.isEmpty {
                let responses = try await session.translations(from: requests)
                var indexed: [Int: String] = [:]
                for response in responses {
                    guard let identifier = response.clientIdentifier, let index = Int(identifier),
                          indexed[index] == nil else { throw TranslationFailure.incomplete }
                    indexed[index] = response.targetText
                }
                guard indexed.count == requests.count else { throw TranslationFailure.incomplete }
                translated = try requests.indices.map { index in
                    guard let text = indexed[index], !text.isEmpty else { throw TranslationFailure.incomplete }
                    return text
                }
                availability = .ready
            }
            try Task.checkCancellation()
            finish(job.id, result: .success(translated))
        } catch {
            finish(job.id, result: .failure(error))
        }
    }

    /// 将请求交给唯一的 SwiftUI 翻译宿主；新请求立即使旧请求失效。
    private func request(_ texts: [String]) async throws -> [String] {
        try Task.checkCancellation()
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let previous = active { finish(previous.id, result: .failure(CancellationError())) }
                active = Job(id: identifier, texts: texts, continuation: continuation)
                requestID = identifier
                isWorking = true
                if configuration == nil {
                    if #available(macOS 26.4, *) {
                        configuration = TranslationSession.Configuration(source: source, target: target,
                                                                         preferredStrategy: .lowLatency)
                    } else {
                        configuration = TranslationSession.Configuration(source: source, target: target)
                    }
                } else {
                    configuration?.invalidate()
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(identifier, result: .failure(CancellationError())) }
        }
    }

    /// 只完成对应请求的 continuation，丢弃晚到的旧会话结果。
    private func finish(_ id: UUID, result: Result<[String], Error>) {
        guard let job = active, job.id == id else { return }
        active = nil
        isWorking = false
        if case .failure(let error) = result, error is CancellationError {
            // 使 SwiftUI 取消对应 translationTask，而不仅仅是丢弃界面结果。
            configuration?.invalidate()
        }
        job.continuation.resume(with: result)
    }
}
