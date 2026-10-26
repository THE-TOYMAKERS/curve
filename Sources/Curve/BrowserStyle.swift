import SwiftUI

enum BrowserType {
    static let commandPointSize: CGFloat = 20
    static func sidebar(selected: Bool = false) -> Font { .system(size: 14, weight: selected ? .medium : .regular) }
    static func titleLabel() -> Font { .system(size: 14, weight: .semibold) }
    static func command() -> Font { .system(size: commandPointSize, weight: .regular) }
    static func caption() -> Font { .system(size: 11) }
    static func shortcut() -> Font { .system(size: 10, weight: .medium, design: .monospaced) }
}

private struct BrowserFullscreenKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var browserFullscreen: Bool {
        get { self[BrowserFullscreenKey.self] }
        set { self[BrowserFullscreenKey.self] = newValue }
    }
}

struct BrowserMotion {
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.32, dampingFraction: 0.88)
    }
    static func quick(reduceMotion: Bool) -> Animation { .easeOut(duration: reduceMotion ? 0.08 : 0.16) }
    static func palette(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -6))
    }
    static func peek(reduceMotion: Bool) -> AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)) }
    static func sidebar(reduceMotion: Bool) -> AnyTransition { reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity) }
    static func tab(reduceMotion: Bool) -> AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -5)) }
}
