import AppKit
@testable import HyperTranslate
import XCTest

@MainActor
final class PanelPinTests: XCTestCase {
    /// 默认不置顶；切换后的偏好可恢复，窗口层级随开关立即更新。
    func testPinPreferenceRestoresAndUpdatesWindowLevel() async throws {
        try withPanel { state, _, panel, preferences in
            XCTAssertFalse(state.isPanelPinned)
            XCTAssertEqual(panel.level, .normal)
            state.isPanelPinned = true
            XCTAssertEqual(panel.level, .floating)

            let restored = AppState(preferences: preferences)
            XCTAssertTrue(restored.isPanelPinned)
            restored.shutdown()

            state.isPanelPinned = false
            XCTAssertEqual(panel.level, .normal)
            let unpinned = AppState(preferences: preferences)
            XCTAssertFalse(unpinned.isPanelPinned)
            unpinned.shutdown()
        }
    }

    /// 外部关闭事件保留置顶结果及进行中的查询，取消置顶后恢复临时窗口关闭逻辑。
    func testPinnedResultSurvivesExternalDismissal() async throws {
        try withPanel { state, controller, panel, _ in
            state.isPanelPinned = true
            controller.show(.result)
            state.isTranslating = true
            controller.dismissTransient()
            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(state.isTranslating)

            state.isPanelPinned = false
            controller.dismissTransient()
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(state.isTranslating)
        }
    }

    /// 置顶后新选区不移动现有浮窗；取消置顶后重新跟随选区，主动关闭仍然有效。
    func testPinKeepsPositionButAllowsExplicitClose() async throws {
        try withPanel { state, controller, panel, _ in
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let first = NSPoint(x: visible.minX + 20, y: visible.maxY - 20)
            let next = NSPoint(x: visible.maxX - 580, y: visible.maxY - 80)
            controller.show(.result, anchor: first)
            let originalFrame = panel.frame
            state.isPanelPinned = true
            controller.show(.result, anchor: next)
            XCTAssertEqual(panel.frame, originalFrame)

            state.isPanelPinned = false
            controller.show(.result, anchor: next)
            XCTAssertNotEqual(panel.frame, originalFrame)
            state.isPanelPinned = true
            state.isTranslating = true
            controller.hide()
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(state.isTranslating)
            XCTAssertTrue(state.isPanelPinned)
        }
    }

    /// 使用独立偏好域和真实原生窗口检查控制器，结束后移除窗口与偏好数据。
    private func withPanel(_ body: (AppState, PanelController, TranslationPanel, UserDefaults) -> Void) throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("原生窗口测试需要可访问屏幕的桌面会话。")
        }
        let domain = "HyperTranslateTests.PanelPin.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        let state = AppState(preferences: preferences)
        let panel = TranslationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        let controller = PanelController(state: state, window: panel)
        defer {
            controller.stop()
            state.shutdown()
            panel.close()
            preferences.removePersistentDomain(forName: domain)
        }
        body(state, controller, panel, preferences)
    }
}
