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
                Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.58 : 0.76)
                LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.04 : 0.14), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.14 : 0.38), lineWidth: 1))
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
                .opacity(reduceTransparency ? 1 : colorScheme == .dark ? 0.72 : 0.82), in: shape)
            .overlay(shape.strokeBorder(.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)))
    }
}

extension View {
    /// 为输入、释义和设置区块应用统一的玻璃内卡片样式。
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

struct GlassToolbarButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var isSelected = false

    /// 使用统一圆角承载导航选中、悬停和按下状态，避免叠加不同形状的底板。
    func makeBody(configuration: Configuration) -> some View {
        GlassToolbarButton(configuration: configuration, size: size, isSelected: isSelected)
    }
}

private struct GlassToolbarButton: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(isSelected ? 0.12 : 0), in: shape)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : isHovered && isEnabled ? 0.06 : 0), in: shape)
            .overlay(shape.strokeBorder(Color.accentColor.opacity(isSelected ? 0.12 : 0)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}
