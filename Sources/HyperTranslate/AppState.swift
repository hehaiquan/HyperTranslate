import AppKit
import Combine
import HyperTranslateCore

@MainActor
final class AppState: ObservableObject {
    enum Page { case result, input, settings, setup }
    @Published var page: Page = .input
    @Published var manualText = ""
    @Published var paused = false
    @Published var hasAccessibility = AXIsProcessTrusted()
    @Published var selectionStatus = "等待选择英文"
    @Published var input: TranslationInput?
    @Published var entry: DictionaryEntry?
    @Published var translation = ""
    @Published var examples: [UsageExample] = []
    @Published var examplesMessage: String?
    @Published var errorMessage: String?
    @Published var dictionaryMessage: String?
    @Published var isTranslating = false
    @Published var isLoadingExamples = false
    @Published var setupMessage: String?
    @Published var isPreparing = false
    let translator = TranslationService()
    let speech = SpeechService()
    private let exampleService = ExampleService()
    private let dictionary: DictionaryStore?
    private var generation = RequestGeneration()
    private var queryTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    var showPanel: ((Page, NSPoint?) -> Void)?

    var accent: String { UserDefaults.standard.string(forKey: "speechAccent") ?? "en-US" }
    var allowsOnlineExamples: Bool { UserDefaults.standard.object(forKey: "onlineExamples") as? Bool ?? true }
    var copyText: String { !translation.isEmpty ? translation : entry?.chineseDefinition ?? "" }

    /// 初始化离线词典；资源异常时保留手动翻译入口并显示原因。
    init() {
        do { dictionary = try DictionaryStore() }
        catch { dictionary = nil; dictionaryMessage = error.localizedDescription }
    }

    /// 开始新查询：立即展示加载状态，先出释义，随后补充例句。
    func query(_ source: String, anchor: NSPoint? = nil) {
        cancelQuery()
        page = .result
        entry = nil
        translation = ""
        examples = []
        examplesMessage = nil
        errorMessage = nil
        speech.stop()
        showPanel?(.result, anchor)
        do { input = try TranslationInput(source) }
        catch { input = nil; errorMessage = error.localizedDescription; return }
        guard let input else { return }
        let identifier = generation.advance()
        isTranslating = true
        queryTask = Task { [weak self] in
            guard let self else { return }
            if input.kind == .word, let dictionary = self.dictionary {
                do {
                    let entry = try await dictionary.lookup(input.text)
                    guard self.isCurrent(identifier) else { return }
                    self.entry = entry
                } catch {
                    guard self.isCurrent(identifier) else { return }
                    self.dictionaryMessage = error.localizedDescription
                }
            }
            guard self.isCurrent(identifier) else { return }
            if self.entry?.chineseDefinition.isEmpty != false {
                do {
                    let output = try await self.translator.translate([input.text])
                    guard self.isCurrent(identifier) else { return }
                    self.translation = output.first ?? ""
                } catch {
                    guard self.isCurrent(identifier) else { return }
                    self.errorMessage = "系统翻译未完成。请检查语言包后重试。\n" + error.localizedDescription
                }
            }
            guard self.isCurrent(identifier) else { return }
            self.isTranslating = false
            if input.kind == .word { await self.loadExamples(identifier: identifier) }
        }
    }

    /// 仅在仍为当前查询时加载、翻译和缓存例句。
    private func loadExamples(identifier: UUID) async {
        guard allowsOnlineExamples else {
            examplesMessage = "联网例句已关闭，可在设置中开启。"
            return
        }
        guard let input else { return }
        let word = entry?.lemma?.word ?? entry?.word ?? input.text
        isLoadingExamples = true
        defer { if generation.contains(identifier) { isLoadingExamples = false } }
        do {
            var examples = try await exampleService.examples(for: word)
            guard isCurrent(identifier) else { return }
            self.examples = examples
            guard !examples.isEmpty else { examplesMessage = "词典暂未收录该词的例句。"; return }
            let missing = examples.indices.filter { examples[$0].chinese == nil }
            if !missing.isEmpty {
                if translator.availability != .ready {
                    await translator.refreshAvailability()
                    guard isCurrent(identifier) else { return }
                }
                guard translator.availability == .ready else {
                    examplesMessage = "英文例句已加载；准备语言包后可显示中文译文。"
                    return
                }
                let translated = try await translator.translate(missing.map { examples[$0].english })
                guard isCurrent(identifier) else { return }
                for (offset, index) in missing.enumerated() { examples[index].chinese = translated[offset] }
                self.examples = examples
                try? await exampleService.save(examples, for: word)
            }
        } catch {
            guard isCurrent(identifier) else { return }
            examplesMessage = examples.isEmpty
                ? "例句暂不可用，可稍后重试；本地查词和翻译仍可使用。"
                : "例句中文翻译未完成，可检查语言包后重试。"
        }
    }

    /// 检查任务是否取消或已被新的查询替代。
    private func isCurrent(_ identifier: UUID) -> Bool {
        !Task.isCancelled && generation.contains(identifier)
    }

    /// 取消旧请求并使晚到的回调失效。
    func cancelQuery() {
        generation.advance()
        queryTask?.cancel()
        queryTask = nil
        isTranslating = false
        isLoadingExamples = false
    }

    /// 按原输入重试完整查询，重新加载未成功的例句。
    func retry() { if let input { query(input.text) } }

    /// 仅在用户点击菜单入口时读取当前剪贴板。
    func translateClipboard() {
        query(NSPasteboard.general.string(forType: .string) ?? "")
    }

    /// 复制当前中文释义或译文，不在后台修改剪贴板。
    func copyTranslation() {
        guard !copyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
    }

    /// 请求系统辅助功能授权，授权结果由设置页定时刷新。
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
        if !hasAccessibility,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 更新授权状态并检查已安装的翻译模型。
    func refreshSetup() async {
        hasAccessibility = AXIsProcessTrusted()
        await translator.refreshAvailability()
    }

    /// 通过唯一翻译宿主准备语言包，显示真实的完成或失败状态。
    func prepareLanguages() {
        guard !isPreparing else { return }
        cancelQuery()
        setupMessage = nil
        isPreparing = true
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.translator.prepare()
                await self.translator.refreshAvailability()
                self.setupMessage = self.translator.availability == .ready
                    ? "语言包已准备好，可以离线翻译。"
                    : "语言包尚未安装完成。如果系统正在后台下载，请稍后点击「检查状态」。"
            } catch {
                self.setupMessage = "语言包准备未完成，可以稍后重试。\n" + error.localizedDescription
            }
            self.isPreparing = false
            await self.translator.refreshAvailability()
        }
    }

    /// 停止后台任务及朗读，供应用退出时调用。
    func shutdown() {
        cancelQuery()
        preparationTask?.cancel()
        speech.stop()
    }
}
