import AppKit
import BrowserCore
import SwiftUI

/// Arc's theme metadata describes a color field, rather than a translucent tint.
/// Keep its base fully opaque so desktop materials cannot dilute the palette.
struct ArcThemeBackdrop: View {
    let space: BrowserSpace

    private var theme: BrowserTheme {
        guard let theme = space.theme, !theme.baseColors.isEmpty else {
            return Self.fallbackTheme(for: space)
        }
        return theme
    }

    var body: some View {
        let theme = theme
        GeometryReader { geometry in
            ZStack {
                Self.color(theme.baseColors[0], opaque: true)
                LinearGradient(
                    colors: theme.baseColors.map { Self.color($0) },
                    startPoint: .leading,
                    endPoint: .trailing
                )
                ForEach(Array(theme.overlayColors.filter { $0.alpha > 0.001 }.enumerated()), id: \.offset) { index, color in
                    RadialGradient(
                        stops: [
                            .init(color: Self.color(color).opacity(0.96), location: 0),
                            .init(color: Self.color(color).opacity(0.58), location: 0.34),
                            .init(color: Self.color(color).opacity(0), location: 1)
                        ],
                        center: Self.overlayOrigin(index),
                        startRadius: 0,
                        endRadius: max(geometry.size.width, geometry.size.height) * 0.92
                    )
                }
                if theme.noise > 0 {
                    Image(nsImage: ThemeGrain.image)
                        .resizable(resizingMode: .tile)
                        .interpolation(.none)
                        .blendMode(.softLight)
                        .opacity(theme.noise * 0.16)
                }
            }
            .saturation((theme.isVibrant ? 0.8 : 0.61) + theme.intensity * 0.25)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func ink(for space: BrowserSpace) -> Color {
        if let ink = space.theme?.ink { return color(ink) }
        return isDark(for: space)
            ? Color.white.opacity(0.93)
            : Color(red: 0.10, green: 0.15, blue: 0.19)
    }

    static func isDark(for space: BrowserSpace) -> Bool {
        if let theme = space.theme { return theme.isDark }
        let value = rgb(space.colorHex)
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return linear(value.red) * 0.2126 + linear(value.green) * 0.7152 + linear(value.blue) * 0.0722 < 0.24
    }

    private static func color(_ value: ThemeColor, opaque: Bool = false) -> Color {
        Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: opaque ? 1 : value.alpha)
    }

    private static func overlayOrigin(_ index: Int) -> UnitPoint {
        switch index % 4 {
        case 0: return .bottomLeading
        case 1: return .topTrailing
        case 2: return .topLeading
        default: return .bottomTrailing
        }
    }

    private static func fallbackTheme(for space: BrowserSpace) -> BrowserTheme {
        let value = rgb(space.colorHex)
        let source = NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        func analogous(_ shift: CGFloat) -> ThemeColor {
            let shifted = (hue + shift + 1).truncatingRemainder(dividingBy: 1)
            let color = NSColor(calibratedHue: shifted, saturation: saturation, brightness: brightness, alpha: 1)
                .usingColorSpace(.sRGB) ?? source
            return ThemeColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        }
        return BrowserTheme(baseColors: [analogous(-0.035), analogous(0.035)], intensity: 0.8,
                            noise: 0.18, isVibrant: true, isDark: isDark(for: space))
    }

    private static func rgb(_ raw: String) -> ThemeColor {
        let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else {
            return ThemeColor(red: 0.66, green: 0.75, blue: 0.87)
        }
        return ThemeColor(red: Double((value >> 16) & 255) / 255,
                          green: Double((value >> 8) & 255) / 255,
                          blue: Double(value & 255) / 255)
    }
}

/// One small, deterministic tile shared by every window. No rendering clock or
/// redraw loop is needed for the fine grain in the surrounding chrome.
private enum ThemeGrain {
    static let image: NSImage = {
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 0xA93E_274B
        for index in 0..<(side * side) {
            seed = 1_664_525 &* seed &+ 1_013_904_223
            let gray = UInt8(80 + ((seed >> 24) % 96))
            pixels[index * 4] = gray
            pixels[index * 4 + 1] = gray
            pixels[index * 4 + 2] = gray
            pixels[index * 4 + 3] = 255
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }()
}
