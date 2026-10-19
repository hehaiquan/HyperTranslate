import AppKit
import Combine
import HyperTranslateCore
import SwiftUI
import Translation

private let brand = Color.blue

struct ShellView: View {
    @ObservedObject var state: AppState
    @ObservedObject var translator: TranslationService
    var close: () -> Void
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let requestID = translator.requestID
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.35)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "character.bubble.fill")
                        .font(.system(size: 19, weight: .medium)).foregroundStyle(brand)
                        .frame(width: 36, height: 36).glassCard(cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HyperTranslate").font(.system(size: 13, weight: .semibold))
                        Text("随选随译 · 自在阅读").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
                .overlay(WindowDragArea())
                .help("按住标题栏拖动窗口")
                Divider().opacity(0.35).padding(.horizontal, 20)
                Group {
                    switch state.page {
                    case .result: ResultView(state: state, speech: state.speech, favorites: state.favorites).id(state.input?.text)
                    case .input: InputView(state: state)
                    case .favorites: FavoritesView(state: state, favorites: state.favorites)
                    case .settings: SettingsView(state: state)
                    case .setup: SetupView(state: state, translator: translator)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.35).padding(.horizontal, 20)
                HStack {
                    Circle().fill(state.paused ? Color.orange : brand).frame(width: 5, height: 5)
                    Text(state.paused ? "划词已暂停" : "英文 → 中文 · " + state.selectionPopupMode.title)
                    Spacer()
                    Text("本地词典 · 系统翻译")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.vertical, 13)
            }
        }
        .tint(brand)
        .background { TranslationGlassBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .translationTask(translator.configuration) { session in
            await translator.perform(using: session, requestID: requestID)
        }
        .task { await state.refreshSetup() }
        .onReceive(permissionTimer) { _ in
            let granted = AXIsProcessTrusted()
            if state.hasAccessibility != granted { state.hasAccessibility = granted }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 14) {
            Button(action: close) { Image(systemName: "xmark") }
                .help("关闭（Esc）").accessibilityLabel("关闭")
                .padding(.bottom, 18)
            sidebarButton("手动输入", symbol: "square.and.pencil", page: .input)
            sidebarButton("收藏单词", symbol: "star", page: .favorites)
            Spacer(minLength: 20)
            sidebarButton("设置", symbol: "gearshape", page: .settings)
        }
        .buttonStyle(GlassToolbarButtonStyle(size: 38))
        .foregroundStyle(.secondary)
        .disabled(state.isPreparing)
        .padding(.vertical, 18)
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(.primary.opacity(0.025))
    }

    /// 构造左侧导航按钮，以高亮和辅助功能状态标记当前页面。
    private func sidebarButton(_ title: String, symbol: String, page: AppState.Page) -> some View {
        Button { state.showPanel?(page, nil) } label: { Image(systemName: symbol) }
            .foregroundStyle(state.page == page ? brand : Color.secondary)
            .background(brand.opacity(state.page == page ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 12))
            .help(title).accessibilityLabel(title)
            .accessibilityAddTraits(state.page == page ? [.isSelected] : [])
    }
}

struct WindowDragArea: NSViewRepresentable {
    /// 提供独立原生拖动区域，避免 SwiftUI 文本、滚动和按钮吞掉窗口拖动事件。
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }

    /// 拖动区域不持有页面状态，页面更新时无需更改原生视图。
    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    /// 结果浮窗未激活时也接收第一次鼠标按下，允许从来源应用直接拖动。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 使用系统窗口拖动，支持非激活浮窗；仅覆盖标题与空白区域。
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct ResultView: View {
    @ObservedObject var state: AppState
    @ObservedObject var speech: SpeechService
    @ObservedObject var favorites: FavoriteStore
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let input = state.input {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(input.kind == .word ? "单词释义" : "原文").sectionLabel()
                            Spacer()
                            if input.kind == .word {
                                Button { state.toggleFavorite() } label: {
                                    Label(favorites.contains(input.text) ? "已收藏" : "收藏",
                                          systemImage: favorites.contains(input.text) ? "star.fill" : "star")
                                }
                                .buttonStyle(.borderless).font(.system(size: 12))
                                .help(favorites.contains(input.text) ? "取消收藏" : "收藏到本机单词本")
                                .disabled(!favorites.contains(input.text) && (state.isTranslating || state.copyText.isEmpty))
                            }
                            Button {
                                if speech.isSpeaking { speech.stop() }
                                else { speech.speak(input.text, accent: state.accent) }
                            } label: {
                                Label(speech.isSpeaking ? "停止" : "朗读", systemImage: speech.isSpeaking ? "stop.fill" : "speaker.wave.2")
                            }.buttonStyle(.borderless).font(.system(size: 12))
                        }
                        Text(input.text)
                            .font(input.kind == .word ? .system(size: 30, weight: .semibold, design: .rounded) : .system(size: 14))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if input.kind == .word {
                            Text(phoneticText).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        if let message = speech.message { Text(message).notice() }
                    }
                    if let entry = state.entry, !entry.chineseDefinition.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if !entry.partOfSpeech.isEmpty {
                                Text("词性 " + entry.partOfSpeech).font(.system(size: 11)).foregroundStyle(brand)
                            }
                            Text(entry.chineseDefinition).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                            if let lemma = entry.lemma {
                                Divider().padding(.vertical, 4)
                                Text("原形 · " + lemma.word).font(.system(size: 12, weight: .semibold)).foregroundStyle(brand)
                                Text(lemma.chineseDefinition).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                            } else if entry.word.lowercased() != input.text.lowercased() {
                                Text("对应词条：" + entry.word).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .glassCard()
                        Text("释义与音标：ECDICT；词库音标不一定与朗读口音一致。")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if !state.translation.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("中文译文").sectionLabel()
                            Text(state.translation).font(.system(size: 16)).lineSpacing(7).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16).glassCard()
                    }
                    if state.isTranslating { loading("正在本地查询与翻译…") }
                    if input.kind == .word {
                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                Text("例句").sectionLabel()
                                Spacer()
                                if let lemma = state.entry?.lemma {
                                    Text("按原形 " + lemma.word + " 查询").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(Array(state.examples.enumerated()), id: \.element.id) { index, example in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(example.english).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                                    if let chinese = example.chinese {
                                        Text(chinese).font(.system(size: 12)).foregroundStyle(.secondary)
                                            .lineSpacing(3).textSelection(.enabled)
                                    }
                                    HStack(spacing: 8) {
                                        if let source = example.sourceURLs.first, let url = safeURL(source) {
                                            Link("来源", destination: url)
                                        }
                                        if let license = example.licenseName, let rawURL = example.licenseURL,
                                           let url = safeURL(rawURL) {
                                            Link(license, destination: url)
                                        }
                                        Spacer()
                                        Button { speech.speak(example.english, accent: state.accent) } label: {
                                            Image(systemName: "speaker.wave.2")
                                        }.buttonStyle(.plain).help("朗读例句")
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                    if index < state.examples.count - 1 { Divider().padding(.top, 6) }
                                }
                            }
                            if state.isLoadingExamples { loading("正在补充例句…") }
                            if let message = state.examplesMessage { Text(message).notice() }
                            if !state.examples.isEmpty {
                                Text("例句按单词查询，可能对应不同词义；中文由系统翻译。")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if let message = state.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle").font(.system(size: 12))
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
                if let message = state.dictionaryMessage { Text(message).notice() }
                if let message = favorites.errorMessage { Text(message).notice() }
                HStack(spacing: 12) {
                    Button {
                        state.copyTranslation()
                        copied = true
                    } label: { Label(copied ? "已复制" : "复制中文", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderedProminent).disabled(state.copyText.isEmpty)
                    Button("重试") { copied = false; state.retry() }
                        .disabled(state.input == nil || state.isTranslating || state.isLoadingExamples)
                    Spacer()
                    if state.errorMessage != nil || state.examplesMessage != nil {
                        Button("语言包") { state.showPanel?(.setup, nil) }.buttonStyle(.borderless)
                    }
                }.font(.system(size: 12))
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var phoneticText: String {
        guard let entry = state.entry, !entry.phonetic.isEmpty else { return "词库暂无音标 · 可点击朗读" }
        let phonetic = entry.phonetic.trimmingCharacters(in: CharacterSet(charactersIn: "/[]"))
        return "/" + phonetic + "/"
    }

    /// 构造简洁的加载提示，不阻塞已显示的释义。
    private func loading(_ text: String) -> some View {
        HStack(spacing: 9) { ProgressView().controlSize(.small); Text(text).font(.system(size: 12)).foregroundStyle(.secondary) }
    }

    /// 仅允许从词典返回的 HTTP 链接打开来源或许可页面。
    private func safeURL(_ string: String) -> URL? {
        guard let url = URL(string: string), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

struct FavoritesView: View {
    @ObservedObject var state: AppState
    @ObservedObject var favorites: FavoriteStore
    @State private var searchText = ""

    private var filteredWords: [FavoriteWord] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? favorites.words : favorites.words.filter {
            $0.word.localizedCaseInsensitiveContains(search) || $0.definition.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("收藏单词").font(.system(size: 23, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(favorites.words.count) 个").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            TextField("搜索单词或中文释义", text: $searchText)
                .textFieldStyle(.roundedBorder).accessibilityLabel("搜索收藏单词")
            if let message = favorites.errorMessage { Text(message).notice() }
            if filteredWords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "star").font(.system(size: 30)).foregroundStyle(brand)
                    Text(favorites.words.isEmpty ? "还没有收藏单词" : "没有找到匹配的收藏")
                        .font(.system(size: 14, weight: .medium))
                    Text(favorites.words.isEmpty ? "查词后点击「收藏」，在这里随时复习。" : "试试其他单词或中文释义。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredWords) { favorite in
                            HStack(alignment: .top, spacing: 12) {
                                Button { state.query(favorite.word) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(favorite.word).font(.system(size: 19, weight: .semibold, design: .rounded))
                                            .foregroundStyle(brand)
                                        if !favorite.phonetic.isEmpty {
                                            Text(favorite.phonetic).font(.system(size: 12)).foregroundStyle(.secondary)
                                        }
                                        Text(favorite.definition).font(.system(size: 13)).foregroundStyle(.primary)
                                            .lineSpacing(4).lineLimit(3)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("重新查询 " + favorite.word)
                                Button { favorites.remove(favorite.word) } label: {
                                    Image(systemName: "star.fill").foregroundStyle(brand)
                                }.buttonStyle(.plain).help("取消收藏 " + favorite.word)
                                    .accessibilityLabel("取消收藏 " + favorite.word)
                            }.padding(14)
                                .glassCard()
                        }
                    }
                }
            }
            Text("收藏保存在本机 · 点击单词重新查询").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(22)
    }
}

struct InputView: View {
    @ObservedObject var state: AppState
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("读到哪里，译到哪里").font(.system(size: 23, weight: .semibold, design: .rounded))
            Text(state.selectionPopupMode.explanation + "\n也可以在这里输入单词、句子或一段文字。")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
            TextEditor(text: $state.manualText).font(.system(size: 15))
                .scrollContentBackground(.hidden).padding(12)
                .glassCard()
                .focused($isFocused).frame(minHeight: 120)
                .accessibilityLabel("输入英文单词、句子或段落")
            HStack {
                Text("\(state.manualText.count) / 12,000").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("翻译") { state.query(state.manualText) }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(state.manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !state.hasAccessibility {
                Button { state.showPanel?(.setup, nil) } label: {
                    Label("开启辅助功能后，可在其他应用划词", systemImage: "hand.point.up.left")
                        .font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(brand)
            }
        }.padding(24).onAppear { isFocused = true }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @AppStorage("speechAccent") private var accent = "en-US"
    @AppStorage("onlineExamples") private var onlineExamples = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("按你的习惯阅读").font(.system(size: 22, weight: .semibold, design: .rounded))
                VStack(alignment: .leading, spacing: 12) {
                    Label("选中后如何弹出", systemImage: "cursorarrow.rays")
                        .font(.system(size: 13, weight: .semibold))
                    Picker("弹出方式", selection: $state.selectionPopupMode) {
                        ForEach(SelectionPopupMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }.pickerStyle(.segmented).labelsHidden()
                        .accessibilityLabel("选中英文后的弹出方式")
                    Text(state.selectionPopupMode.explanation).notice()
                    Divider().opacity(0.5)
                    Toggle("暂停划词", isOn: $state.paused)
                    Text("暂停后，两种模式均不触发；仍可手动输入或翻译剪贴板。")
                        .notice()
                }.padding(16).glassCard()
                VStack(alignment: .leading, spacing: 12) {
                    Text("例句与翻译").sectionLabel()
                    Toggle("联网补充英文例句", isOn: $onlineExamples)
                    Text("仅查询的单词会发送到 Free Dictionary API。整句翻译在本机完成；关闭此项后不读取例句缓存。")
                        .notice()
                }.padding(16).glassCard()
                VStack(alignment: .leading, spacing: 12) {
                    Text("英语朗读").sectionLabel()
                    Picker("口音", selection: $accent) {
                        Text("美式英语").tag("en-US")
                        Text("英式英语").tag("en-GB")
                    }.pickerStyle(.segmented)
                    Button("试听 Hello") { state.speech.speak("Hello. Welcome to HyperTranslate.", accent: accent) }
                        .buttonStyle(.borderless)
                    Text("使用系统合成语音。词库音标单独提供，缺失时不会根据朗读推测音标。")
                        .notice()
                }.padding(16).glassCard()
                HStack {
                    Button("权限与语言包") { state.showPanel?(.setup, nil) }
                    Spacer()
                    Button("手动翻译") { state.showPanel?(.input, nil) }.buttonStyle(.borderedProminent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("HyperTranslate 1.0.6").font(.system(size: 12, weight: .medium))
                    Text("ECDICT · Free Dictionary API / Wiktionary\n不保存翻译历史，只缓存例句及其中文译文。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("查看第三方来源与许可") {
                        if let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") {
                            NSWorkspace.shared.open(url)
                        }
                    }.font(.system(size: 11)).buttonStyle(.borderless)
                }
            }.padding(24)
        }
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState
    @ObservedObject var translator: TranslationService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("两步，开始轻松阅读").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("单词释义与音标已经内置。完成以下准备，即可在其他应用划词，并离线翻译句子。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                setupStep(number: "1", title: "允许读取选中文字", ready: state.hasAccessibility) {
                    Text("在「隐私与安全性 → 辅助功能」中开启 HyperTranslate。授权后会自动检测。")
                        .notice()
                    Button(state.hasAccessibility ? "已授权" : "打开辅助功能设置") { state.requestAccessibility() }
                        .disabled(state.hasAccessibility || state.isPreparing)
                    Text("取词状态：" + state.selectionStatus).notice().textSelection(.enabled)
                }
                setupStep(number: "2", title: "准备英文与中文语言包", ready: translator.availability == .ready) {
                    Text(languageDescription).notice()
                    if state.isPreparing {
                        HStack { ProgressView().controlSize(.small); Text("请在系统提示中确认下载…").font(.system(size: 12)) }
                    } else {
                        HStack {
                            if translator.availability != .ready {
                                Button("准备语言包") { state.prepareLanguages() }
                                    .disabled(translator.availability == .unsupported || translator.availability == .checking)
                            }
                            Button("检查状态") { Task { await state.refreshSetup() } }
                        }
                    }
                    if let message = state.setupMessage { Text(message).notice().textSelection(.enabled) }
                }
                Button("开始使用") {
                    UserDefaults.standard.set(true, forKey: "completedOnboarding")
                    state.showPanel?(.input, nil)
                }.buttonStyle(.borderedProminent).disabled(state.isPreparing)
                Text("暂不授权也可以手动输入或从菜单翻译剪贴板。图片及扫描 PDF 不属于本版取词范围。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(24)
        }
        .task { await state.refreshSetup() }
    }

    private var languageDescription: String {
        switch translator.availability {
        case .checking: return "正在检查系统语言包…"
        case .ready: return "语言包已安装，句子翻译无需联网。"
        case .needsDownload: return "首次使用可能需要联网下载，系统会显示确认提示；完成后可离线使用。"
        case .unsupported: return "当前系统无法提供英译中服务。本地单词查询仍可使用。"
        }
    }

    /// 构造带完成状态的准备步骤。
    private func setupStep<Content: View>(number: String, title: String, ready: Bool,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Group {
                if ready { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                else { Text(number).font(.system(size: 13, weight: .semibold)) }
            }.foregroundStyle(brand).frame(width: 28, height: 28).background(brand.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold))
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension Text {
    /// 统一次级区块标题的字重与色彩。
    func sectionLabel() -> some View {
        font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    /// 统一说明和降级提示的阅读样式。
    func notice() -> some View {
        font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}
