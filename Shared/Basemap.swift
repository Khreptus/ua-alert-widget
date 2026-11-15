import SwiftUI
import WebKit

/// Vector basemap (OpenFreeMap "dark"/"positron" styles rendered by MapLibre GL in a web view),
/// kept in sync with the SwiftUI map's zoom/offset. Used only in the app, never in WidgetKit.
struct BasemapView: NSViewRepresentable {
    let view: (lat: Double, lon: Double, zoom: Double)
    let dark: Bool

    final class PassiveWebView: WKWebView {
        var ready = false
        var pending: String?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let w = webView as? PassiveWebView else { return }
            w.ready = true
            if let js = w.pending { w.evaluateJavaScript(js) }
            w.pending = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassiveWebView {
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = false
        let w = PassiveWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        w.navigationDelegate = context.coordinator
        if let url = Bundle.main.url(forResource: "basemap", withExtension: "html") {
            w.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return w
    }

    func updateNSView(_ w: PassiveWebView, context: Context) {
        let js = String(format: "window.jump&&jump(%.6f,%.6f,%.4f,'%@')", view.lat, view.lon, view.zoom, dark ? "dark" : "light")
        if w.ready { w.evaluateJavaScript(js) } else { w.pending = js }
    }
}
