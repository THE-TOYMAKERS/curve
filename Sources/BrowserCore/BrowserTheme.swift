import Foundation

public struct ThemeColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func bounded(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
        self.red = bounded(red); self.green = bounded(green); self.blue = bounded(blue); self.alpha = bounded(alpha)
    }
    public var hex: String { String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())) }
}

/// The full color field, rather than Arc's pale UI-tint swatch. Only theme
/// metadata is preserved; rendering is native and independent of Arc's runtime.
public struct BrowserTheme: Codable, Equatable, Sendable {
    public var baseColors: [ThemeColor]
    public var overlayColors: [ThemeColor]
    public var intensity: Double
    public var noise: Double
    public var isVibrant: Bool
    public var isDark: Bool
    public var ink: ThemeColor?
    public init(baseColors: [ThemeColor], overlayColors: [ThemeColor] = [], intensity: Double = 0.8, noise: Double = 0.2, isVibrant: Bool = true, isDark: Bool = false, ink: ThemeColor? = nil) {
        self.baseColors = Array(baseColors.prefix(8)); self.overlayColors = Array(overlayColors.prefix(8))
        self.intensity = intensity.isFinite ? min(1, max(0, intensity)) : 0.8
        self.noise = noise.isFinite ? min(1, max(0, noise)) : 0.2
        self.isVibrant = isVibrant; self.isDark = isDark; self.ink = ink
    }
}
