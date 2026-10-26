import AppKit
import Foundation
import WebKit

@main
struct EngineSmoke {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let engine = WebEngine()
            let id = UUID()
            engine.openHTML(id: id, html: "<html><head><title>Curve smoke test</title></head><body><h1>Native WebKit works</h1><input id='draft'><a href='https://example.com'>Link</a><script>window.answer=6*7</script></body></html>", baseURL: URL(string:"https://curve.test"))
            let view = engine.webView(for: id, url: URL(string:"https://curve.test")!)
            var failures: [String] = []
            for _ in 0..<80 {
                if view.title == "Curve smoke test" { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if view.title != "Curve smoke test" { failures.append("HTML/title load") }
            let result = try? await view.evaluateJavaScript("window.answer")
            if result as? Int != 42 { failures.append("JavaScript evaluation") }
            if engine.webView(for:id,url:URL(string:"https://example.com")!) !== view { failures.append("stable view identity") }
            engine.zoom(id:id,factor:1.2)
            if abs(view.pageZoom - 1.2) > 0.01 { failures.append("page zoom") }
            let found = await withCheckedContinuation { continuation in
                engine.onFindResult = { continuation.resume(returning:$0) }
                engine.find(id:id,query:"Native WebKit")
            }
            if !found { failures.append("find in page") }
            engine.clearFind(id:id)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            let oldHost = WebContentHost(webView: view)
            window.contentView?.addSubview(oldHost)
            oldHost.setFrameSize(NSSize(width: 300, height: 400))
            if view.superview !== oldHost || view.frame != oldHost.bounds { failures.append("initial zero-size mount follows its first nonzero frame") }
            let unusedHost = WebContentHost(webView: view)
            oldHost.layoutSubtreeIfNeeded()
            unusedHost.releaseWebView()
            if view.superview !== oldHost { failures.append("unmounted host cannot steal a visible page") }
            let newHost = WebContentHost(webView: view)
            newHost.frame = NSRect(x: 0, y: 0, width: 620, height: 440)
            window.contentView?.addSubview(newHost)
            oldHost.setWebView(view)
            oldHost.releaseWebView()
            oldHost.removeFromSuperview()
            newHost.layoutSubtreeIfNeeded()
            if view.superview !== newHost || view.frame != newHost.bounds { failures.append("page host handoff retains visible page") }
            if (try? await view.evaluateJavaScript("window.answer")) as? Int != 42 { failures.append("page host handoff preserves document") }
            let overlayHost = WebContentHost(webView: view)
            overlayHost.frame = newHost.frame
            window.contentView?.addSubview(overlayHost)
            overlayHost.removeFromSuperview()
            overlayHost.releaseWebView()
            if view.superview !== newHost { failures.append("detached host returns page to surviving mount") }
            newHost.releaseWebView()
            window.close()
            for _ in 0..<4 {
                engine.openHTML(id:UUID(),html:"<html><body>Idle tab</body></html>")
            }
            engine.activate(ids:[id],limit:2)
            try? await Task.sleep(nanoseconds:1_000_000_000)
            if engine.liveCount > 2 { failures.append("LRU session eviction: \(engine.liveCount)") }
            if engine.webView(for:id,url:URL(string:"https://curve.test")!) !== view { failures.append("active view retained") }
            engine.close(id:id)
            if !engine.state(id:id).isSuspended { failures.append("close releases session") }
            print(failures.isEmpty ? "PASS: real WKWebView HTML/title, JavaScript, stable identity, zoom, find, page host handoff, LRU eviction, active retention, close" : "FAIL: \(failures.joined(separator:", "))")
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
        }
        application.run()
    }
}
