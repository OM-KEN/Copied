import AppKit
import Foundation

/// 颜色检测器 — 检测 hex (#RGB/#RRGGBB/#RRGGBBAA)、rgb()、hsl()。
/// 颜色检测不产生动作按钮，仅用于显示色块。
struct ColorDetector: ContentDetectorProtocol {
    let kind = ContentKind.colorHex  // 统一使用 colorHex（内部区分格式）
    let priority = 300

    private static let rgbRegex = try! NSRegularExpression(pattern: #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*(0|1|0?\.\d+|[01]\.\d+))?\s*\)$"#)
    private static let hslRegex = try! NSRegularExpression(pattern: #"^hsl\(\s*(\d{1,3})\s*,\s*(\d{1,3})%\s*,\s*(\d{1,3})%\s*\)$"#)

    func detect(in text: String) -> ContentDetection? {
        // Hex with #: #RGB, #RRGGBB, #RRGGBBAA
        let hexPattern = #"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#
        if let match = text.range(of: hexPattern, options: .regularExpression),
           match == text.startIndex..<text.endIndex,
           let color = parseHexColor(String(text)) {
            return ContentDetection(
                kind: .colorHex, value: String(text), color: color,
                metadata: ["format": "hex"]
            )
        }

        // Bare 6-digit hex
        let bareHexPattern = #"^[0-9a-fA-F]{6}$"#
        if text.range(of: bareHexPattern, options: .regularExpression) != nil,
           let color = parseHexColor("#\(text)") {
            return ContentDetection(
                kind: .colorHex, value: "#\(text)", color: color,
                metadata: ["format": "hex"]
            )
        }

        // rgb() / rgba()
        if let color = parseRGBColor(text, regex: Self.rgbRegex) {
            return ContentDetection(
                kind: .colorRGB, value: text, color: color,
                metadata: ["format": "rgb"]
            )
        }

        // hsl()
        if let color = parseHSLColor(text, regex: Self.hslRegex) {
            return ContentDetection(
                kind: .colorHSL, value: text, color: color,
                metadata: ["format": "hsl"]
            )
        }

        return nil
    }

    // MARK: Hex parsing

    private func parseHexColor(_ hex: String) -> NSColor? {
        var hex = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8 else { return nil }

        var int: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&int) else { return nil }

        let r, g, b, a: CGFloat
        if hex.count == 8 {
            r = CGFloat((int >> 24) & 0xFF) / 255
            g = CGFloat((int >> 16) & 0xFF) / 255
            b = CGFloat((int >> 8) & 0xFF) / 255
            a = CGFloat(int & 0xFF) / 255
        } else {
            r = CGFloat((int >> 16) & 0xFF) / 255
            g = CGFloat((int >> 8) & 0xFF) / 255
            b = CGFloat(int & 0xFF) / 255
            a = 1.0
        }
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: RGB parsing

    private func parseRGBColor(_ text: String, regex: NSRegularExpression) -> NSColor? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range.location != NSNotFound else { return nil }

        let nsText = text as NSString
        guard let r = Int(nsText.substring(with: match.range(at: 1))),
              let g = Int(nsText.substring(with: match.range(at: 2))),
              let b = Int(nsText.substring(with: match.range(at: 3))),
              (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else { return nil }

        let a: CGFloat
        if match.range(at: 4).location != NSNotFound {
            a = CGFloat(Double(nsText.substring(with: match.range(at: 4))) ?? 1.0)
        } else {
            a = 1.0
        }
        return NSColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
    }

    // MARK: HSL parsing

    private func parseHSLColor(_ text: String, regex: NSRegularExpression) -> NSColor? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range.location != NSNotFound else { return nil }

        let nsText = text as NSString
        guard let h = Double(nsText.substring(with: match.range(at: 1))),
              let s = Double(nsText.substring(with: match.range(at: 2))),
              let l = Double(nsText.substring(with: match.range(at: 3))),
              (0...360).contains(h), (0...100).contains(s), (0...100).contains(l) else { return nil }

        let sNorm = s / 100
        let lNorm = l / 100
        let c = (1 - abs(2 * lNorm - 1)) * sNorm
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lNorm - c / 2

        var r, g, b: Double
        switch h {
        case 0..<60:   (r, g, b) = (c, x, 0)
        case 60..<120:  (r, g, b) = (x, c, 0)
        case 120..<180: (r, g, b) = (0, c, x)
        case 180..<240: (r, g, b) = (0, x, c)
        case 240..<300: (r, g, b) = (x, 0, c)
        default:        (r, g, b) = (c, 0, x)
        }

        return NSColor(red: r + m, green: g + m, blue: b + m, alpha: 1.0)
    }
}
