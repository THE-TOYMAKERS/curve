import AppKit
import Foundation
import WebKit

@main
struct EnginePrivate {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let privateA = WebEngine(isPrivate:true)
            let privateB = WebEngine(isPrivate:true)
            let regular = WebEngine()
            let url = URL(string:"about:blank")!
            let storeA = privateA.webView(for:UUID(),url:url).configuration.websiteDataStore
            let storeA2 = privateA.webView(for:UUID(),url:url).configuration.websiteDataStore
            let storeB = privateB.webView(for:UUID(),url:url).configuration.websiteDataStore
            let storeRegular = regular.webView(for:UUID(),url:url).configuration.websiteDataStore
            var failures:[String] = []
            if storeA.isPersistent || storeB.isPersistent { failures.append("private stores must be nonpersistent") }
            if !storeRegular.isPersistent { failures.append("regular store must persist") }
            if storeA !== storeA2 { failures.append("private tabs do not share the window store") }
            if storeA === storeB { failures.append("private windows share store identity") }
            let cookie = HTTPCookie(properties:[.domain:"curve.test",.path:"/",.name:"curve-private-smoke",.value:"ephemeral"])!
            await storeA.httpCookieStore.setCookie(cookie)
            let cookiesA = await storeA2.httpCookieStore.allCookies()
            let cookiesB = await storeB.httpCookieStore.allCookies()
            if !cookiesA.contains(where:{$0.name == cookie.name}) { failures.append("same private window cookie sharing") }
            if cookiesB.contains(where:{$0.name == cookie.name}) { failures.append("separate private window cookie isolation") }
            privateA.shutdown()
            if privateA.liveCount != 0 { failures.append("shutdown releases all sessions") }
            _ = privateA.webView(for: UUID(), url: URL(string: "https://example.com")!)
            if privateA.liveCount != 0 { failures.append("closed engine recreated a session") }
            privateA.shutdown()
            var privateCookiesCleared = false
            for _ in 0..<40 {
                let cookies = await storeA.httpCookieStore.allCookies()
                if !cookies.contains(where: { $0.name == cookie.name }) { privateCookiesCleared = true; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if !privateCookiesCleared { failures.append("private shutdown clears ephemeral cookies") }
            privateB.shutdown(); regular.shutdown()
            print(failures.isEmpty ? "PASS: nonpersistent private stores, persistent regular store, shared private tabs, isolated private windows, shutdown releases sessions and cookies without recreation" : "FAIL: \(failures)")
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
