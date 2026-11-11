import SwiftUI
import AppKit
import BrowserCore

struct PrivacyPanel: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var engine: WebEngine
    @ObservedObject private var privacy = PrivacySettings.shared
    @ObservedObject private var coordinator = BrowserCoordinator.shared
    @StateObject private var updates = ReleaseUpdateChecker()
    @Environment(\.dismiss) private var dismiss
    @State private var clearHistory = true
    @State private var clearWebsites = true
    @State private var clearTabs = false
    @State private var result: String?

    private var page: WebPageState { engine.state(id: store.currentID ?? UUID()) }
    private var origin: String {
        guard let url = URL(string: page.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return "No website open" }
        return URLSecurity.displayOrigin(for: url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelHeading(title: "Curve Shields", subtitle: engine.isPrivate ? "PRIVATE WINDOW · TEMPORARY DATA" : "PERSISTENT WINDOW · SHARED WEBSITE PROFILE", symbol: "shield.lefthalf.filled", close: { dismiss() })
            HStack(spacing: 9) {
                Image(systemName: page.protectionReady ? "checkmark.shield.fill" : "shield")
                    .foregroundStyle(page.protectionReady ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(origin).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    Text(page.protectionReady ? "Native blocking rules installed" : "Blocking rules must be verified before a page loads")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            Form {
                Section("Protection") {
                    Picker("Ads & trackers", selection: $privacy.protectionLevel) {
                        Text("Strict").tag(ProtectionLevel.strict)
                        Text("Balanced").tag(ProtectionLevel.balanced)
                    }
                    Text("Strict blocks listed ads and trackers on all sites. Balanced limits network blocking to third-party requests. Both hide common ad placements; some sites may need Balanced.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Require HTTPS for public websites", isOn: $privacy.httpsOnly)
                    Toggle("Block page JavaScript", isOn: $privacy.blockJavaScript)
                    Text("Blocking scripts disables many logins and interactive sites. Changing protection settings reloads open documents; save unfinished forms first.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Send Global Privacy Control", isOn: $privacy.sendGlobalPrivacyControl)
                    Text("Asks websites to limit data sale and sharing. Sites can ignore the signal. Curve sends it on initial page requests and through the page's privacy-control setting.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Bundled blocking domains", value: ContentProtection.bundledDomainCount.formatted())
                    LabeledContent("List snapshot", value: ContentProtection.sourceDate)
                    Text("No ad replacement or rewards program. Embedded video and first-party ads can still appear. Lists are bundled with app updates; browsing addresses are not sent to a filtering server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Private browsing") {
                    if let warning = privacy.cleanupWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    }
                    Toggle("Open private windows by default", isOn: $privacy.privateByDefault)
                    Text("Applies to new windows and next launch. Private windows keep history, cookies and tabs out of saved browsing data. Downloads, exported files and clipboard items remain. Sites and your network provider can still see activity.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Use File → New Persistent Window when you deliberately want saved tabs and website logins. Spaces organize tabs; they do not isolate accounts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Clear browsing data · all Curve windows") {
                    Toggle("History and archived tabs", isOn: $clearHistory).disabled(clearTabs)
                    Toggle("Cookies, cache and website storage", isOn: $clearWebsites)
                    Toggle("Saved tabs, pins and folders (includes history)", isOn: $clearTabs)
                        .onChange(of: clearTabs) { _, enabled in if enabled { clearHistory = true } }
                    Text("Clearing website data signs you out and closes Today tabs in every window. Pins remain unless selected above. Clearing saved metadata also removes its recovery backups; external backups and filesystem snapshots are outside Curve's control.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clear Selected Data…", role: .destructive, action: confirmErasure)
                        .disabled(coordinator.isErasingData || !(clearHistory || clearWebsites || clearTabs))
                    if coordinator.isErasingData { ProgressView("Clearing all windows…") }
                    if let result { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Section("Updates & security") {
                    Text("WebKit security fixes arrive through Apple updates. Curve's own code also needs updates. This preview is experimental and has not had an independent security audit.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(updates.isChecking ? "Checking…" : "Check for Updates") { Task { await updates.check() } }
                        .disabled(updates.isChecking)
                    if let message = updates.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let url = updates.releaseURL {
                        Link("View Official Release", destination: url)
                    }
                    Text("Update checks contact GitHub only when requested. Installation is manual; this checker never downloads or executes an update.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.padding(22).frame(width: 620, height: 720)
    }

    private func confirmErasure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear selected browsing data in every Curve window?"
        alert.informativeText = "This cannot be undone. Cookie clearing signs you out and closes Today tabs. Saved tabs, pins and folders are removed only when selected. Files you downloaded or exported are retained."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear Data")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertSecondButtonReturn else { return }
            Task { @MainActor in
                do {
                    try await coordinator.eraseBrowsingData(history: clearHistory, websiteData: clearWebsites, savedTabs: clearTabs)
                    result = "Selected live browsing data and saved recovery files were cleared."
                } catch {
                    result = "Clearing did not finish: \(error.localizedDescription). Do not assume all selected data was removed."
                }
            }
        }
        if let window = store.window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }
}
