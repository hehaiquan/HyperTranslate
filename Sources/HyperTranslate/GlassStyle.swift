import AppKit
import SwiftUI

/// 全窗玻璃底板：新系统使用 Liquid Glass，旧系统保留原生背景模糊。
struct TranslationGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                NativeGlassMaterial()
            }
            if !reduceTransparency {
                LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.10 : 0.30), .clear,
                                        .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.18 : 0.58), lineWidth: 1))
        .overlay(shape.inset(by: 1).strokeBorder(.primary.opacity(0.04), lineWidth: 1))
        .allowsHitTesting(false)
    }
}

private struct NativeGlassMaterial: NSViewRepresentable {
    /// 让材质采样窗口背后的桌面和应用，而非仅模糊浮窗内部内容。
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    /// 材质由系统自动适配深浅色，无需在页面更新时重新创建。
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct GlassCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat

    /// 使用柔和的实体底色承托正文，避免多层模糊降低文字可读性。
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color(nsColor: .controlBackgroundColor)
                .opacity(reduceTransparency ? 1 : colorScheme == .dark ? 0.48 : 0.64), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.10 : 0.55)))
    }
}

extension View {
    /// 为输入、释义和设置区块应用统一的玻璃内卡片样式。
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

struct GlassToolbarButtonStyle: ButtonStyle {
    var size: CGFloat = 30

    /// 统一工具栏按钮的圆形点击区域，并保留按下时的系统反馈。
    func makeBody(configuration: Configuration) -> some View {
        GlassToolbarButton(configuration: configuration, size: size)
    }
}

private struct GlassToolbarButton: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: size, height: size)
            .background(.primary.opacity(configuration.isPressed ? 0.14 : isHovered && isEnabled ? 0.08 : 0.035), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.16)))
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}
