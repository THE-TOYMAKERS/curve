import AppKit
import SwiftUI

@MainActor
final class WindowChrome: ObservableObject {
    @Published var isFullScreen = false
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        self.window = window
        isFullScreen = window.styleMask.contains(.fullScreen)
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification, NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] note in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.isFullScreen = note.name == NSWindow.willEnterFullScreenNotification || (note.name != NSWindow.willExitFullScreenNotification && window.styleMask.contains(.fullScreen))
                }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor
enum BrowserLaunchPresentation {
    private static var presented = false
    static func claim() -> Bool { guard !presented else { return false }; presented = true; return true }
}

struct LaunchBloom: View {
    let reduceMotion: Bool
    @State private var opened = false
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.32)).frame(width: 170, height: 170).blur(radius: 45)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().scaledToFit().frame(width: 64, height: 64)
                .rotationEffect(.degrees(reduceMotion ? 0 : opened ? 22 : -32))
                .scaleEffect(reduceMotion ? 1 : opened ? 1 : 0.78)
        }
        .opacity(opened ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.48, dampingFraction: 0.82)) { opened = true } }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
