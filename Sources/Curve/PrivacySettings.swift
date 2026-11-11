import Foundation
import Combine
import BrowserCore

/// Only non-browsing preferences are saved. Site exceptions stay in a window's engine.
@MainActor
final class PrivacySettings: ObservableObject {
    static let shared = PrivacySettings()
    static let didChange = Notification.Name("CurvePrivacySettingsChanged")
    private let defaults: UserDefaults
    @Published var cleanupWarning: String?
    @Published var privateByDefault: Bool { didSet { save(reloadPages: false) } }
    @Published var protectionLevel: ProtectionLevel { didSet { save() } }
    @Published var httpsOnly: Bool { didSet { save() } }
    @Published var blockJavaScript: Bool { didSet { save() } }
    @Published var sendGlobalPrivacyControl: Bool { didSet { save() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        privateByDefault = defaults.object(forKey: "privacy.privateByDefault") as? Bool ?? true
        let stored = defaults.string(forKey: "privacy.protectionLevel") ?? "strict"
        // Globally disabled protection is deliberately not a saved preference.
        protectionLevel = stored == "balanced" ? .balanced : .strict
        httpsOnly = defaults.object(forKey: "privacy.httpsOnly") as? Bool ?? true
        blockJavaScript = defaults.object(forKey: "privacy.blockJavaScript") as? Bool ?? false
        sendGlobalPrivacyControl = defaults.object(forKey: "privacy.gpc") as? Bool ?? true
    }

    private func save(reloadPages: Bool = true) {
        defaults.set(privateByDefault, forKey: "privacy.privateByDefault")
        defaults.set(protectionLevel == .balanced ? "balanced" : "strict", forKey: "privacy.protectionLevel")
        defaults.set(httpsOnly, forKey: "privacy.httpsOnly")
        defaults.set(blockJavaScript, forKey: "privacy.blockJavaScript")
        defaults.set(sendGlobalPrivacyControl, forKey: "privacy.gpc")
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["reloadPages": reloadPages])
    }
}
