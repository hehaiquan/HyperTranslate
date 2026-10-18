import AppKit

/// 绘制原生应用图标，生成所有标准 Retina 尺寸。
func createIcon(at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            let image = NSImage(size: NSSize(width: pixels, height: pixels))
            image.lockFocus()
            let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
            let inset = CGFloat(pixels) * 0.055
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                          xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22)
            NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.62, blue: 0.52, alpha: 1),
                       ending: NSColor(srgbRed: 0.04, green: 0.35, blue: 0.34, alpha: 1))!
                .draw(in: background, angle: -70)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let font = NSFont.systemFont(ofSize: CGFloat(pixels) * 0.53, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white,
                                                            .paragraphStyle: paragraph]
            let text = "译" as NSString
            let height = text.size(withAttributes: attributes).height
            let side = CGFloat(pixels)
            let baseline = (side - height) / 2 - side * 0.015
            let textRect = NSRect(x: 0, y: baseline, width: side, height: height + 2)
            text.draw(in: textRect, withAttributes: attributes)
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "HyperTranslate.Icon", code: 1)
            }
            let suffix = scale == 2 ? "@2x" : ""
            try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
}

try createIcon(at: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
