import AppKit
import Combine
import Foundation
import HyperTranslateCore

@main
struct HyperTranslateApplication {
    /// 启动原生菜单栏应用；诊断参数只读检查打包资源和接口。
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            Task {
                await Diagnostics.run(includeNetwork: CommandLine.arguments.contains("--network"))
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState()
    private var panels: PanelController!
    private var selection: SelectionService!
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var subscriptions = Set<AnyCancellable>()

    /// 建立菜单栏、取词监听和首次使用引导。
    func applicationDidFinishLaunching(_ notification: Notification) {
        panels = PanelController(state: state)
        selection = SelectionService(state: state)
        selection.onSelection = { [weak self] snapshot in self?.panels.showIndicator(snapshot) }
        selection.onDismiss = { [weak self] in self?.panels.dismissTransient() }
        selection.start()
        createMainMenu()
        createMenu()
        state.$paused.sink { [weak self] paused in
            guard let self else { return }
            self.selection.invalidate()
            if paused { self.panels.dismissTransient() }
            self.statusItem.button?.alphaValue = paused ? 0.5 : 1
        }.store(in: &subscriptions)
        state.$hasAccessibility.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.selection.stop()
            self?.selection.start()
        }.store(in: &subscriptions)
        if CommandLine.arguments.contains("--show-input") {
            panels.show(.input)
        } else if !UserDefaults.standard.bool(forKey: "completedOnboarding") {
            panels.show(.setup)
        }
    }

    /// 为原生文本编辑器提供标准撤销、复制、粘贴和全选快捷键。
    private func createMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "HyperTranslate")
        appMenu.addItem(item("退出 HyperTranslate", action: #selector(quit), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
                                        ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                        ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// 构造菜单栏入口，剪贴板仅在对应菜单项被点击时读取。
    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "HyperTranslate")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("手动翻译…", action: #selector(showInput), key: "t"))
        menu.addItem(item("翻译剪贴板", action: #selector(translateClipboard), key: ""))
        menu.addItem(.separator())
        pauseItem = item("暂停划词", action: #selector(togglePause), key: "")
        menu.addItem(pauseItem)
        menu.addItem(item("权限与语言包…", action: #selector(showSetup), key: ""))
        menu.addItem(item("设置…", action: #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("退出 HyperTranslate", action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    /// 创建指定动作的原生菜单项。
    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// 每次打开菜单时同步暂停状态。
    func menuWillOpen(_ menu: NSMenu) {
        pauseItem.title = state.paused ? "恢复划词" : "暂停划词"
        pauseItem.state = state.paused ? .on : .off
    }

    /// 打开输入页面。
    @objc private func showInput() { panels.show(.input) }
    /// 通过明确的菜单操作读取剪贴板并翻译。
    @objc private func translateClipboard() { state.translateClipboard() }
    /// 切换自动划词状态。
    @objc private func togglePause() { state.paused.toggle() }
    /// 打开权限和语言包准备页面。
    @objc private func showSetup() { panels.show(.setup) }
    /// 打开应用设置。
    @objc private func showSettings() { panels.show(.settings) }
    /// 退出菜单栏应用。
    @objc private func quit() { NSApp.terminate(nil) }

    /// 从 Finder 再次打开时显示手动翻译页面。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panels.show(.input)
        return true
    }

    /// 不因关闭浮窗而退出常驻应用。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 退出前移除系统监听并取消所有任务。
    func applicationWillTerminate(_ notification: Notification) {
        selection.stop()
        panels.stop()
        state.shutdown()
    }
}

enum Diagnostics {
    /// 检查真实打包词库；可选择验证例句接口，不修改授权或下载系统模型。
    @MainActor static func run(includeNetwork: Bool) async {
        var result: [String: Any] = ["macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                                     "accessibility": AXIsProcessTrusted()]
        do {
            let store = try DictionaryStore()
            result["dictionaryEntries"] = try await store.entryCount()
            for word in ["hello", "gave", "saw", "teeth"] {
                if let entry = try await store.lookup(word) {
                    result[word] = ["word": entry.word, "phonetic": entry.phonetic,
                                    "chinese": entry.chineseDefinition, "lemma": entry.lemma?.word ?? ""]
                }
            }
        } catch { result["dictionaryError"] = error.localizedDescription }
        if includeNetwork {
            do {
                let service = ExampleService()
                result["networkExamples"] = try await service.examples(for: "hello").map(\.english)
            } catch { result["networkError"] = error.localizedDescription }
        }
        let translator = TranslationService()
        await translator.refreshAvailability()
        result["translationAvailability"] = String(describing: translator.availability)
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
