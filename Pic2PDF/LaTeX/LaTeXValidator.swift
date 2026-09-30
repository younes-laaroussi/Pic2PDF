//
//  LaTeXValidator.swift
//  Pic2PDF
//
//  Checks LaTeX with latex.js's own parser, i.e. the same library that renders the preview and the
//  PDF, so "valid" means "will display".
//

import Foundation
import WebKit

@MainActor
final class LaTeXValidator: NSObject, WKNavigationDelegate {
    static let shared = LaTeXValidator()

    struct Issue: Equatable {
        let message: String
        let line: Int?
        let column: Int?
    }

    private var webView: WKWebView?
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    private func prepare() async {
        if ready { return }
        if webView == nil {
            let config = WKWebViewConfiguration()
            LaTeXJSAssets.install(in: config)
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = self
            webView = view
            let html = """
            <!DOCTYPE html><html><head><meta charset="UTF-8">
            <script src="\(LaTeXJSAssets.baseURL.absoluteString)latex.js"></script></head><body></body></html>
            """
            view.loadHTMLString(html, baseURL: LaTeXJSAssets.baseURL)
        }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.ready = true
            let waiters = self.readyWaiters
            self.readyWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    /// Returns nil if latex.js parses the document, otherwise its error.
    func validate(_ latex: String) async -> Issue? {
        await prepare()
        guard let webView else { return Issue(message: "Validator unavailable", line: nil, column: nil) }
        let script = """
        try {
          latexjs.parse(src, { generator: new latexjs.HtmlGenerator({ hyphenate: false }) });
          return null;
        } catch (e) {
          const loc = e.location && e.location.start;
          return { message: String(e.message || e), line: loc ? loc.line : null, column: loc ? loc.column : null };
        }
        """
        do {
            let result = try await webView.callAsyncJavaScript(script, arguments: ["src": latex], contentWorld: .page)
            guard let dict = result as? [String: Any] else { return nil }
            return Issue(message: dict["message"] as? String ?? "Unknown LaTeX error",
                         line: dict["line"] as? Int, column: dict["column"] as? Int)
        } catch {
            return Issue(message: "Validator failed: \(error.localizedDescription)", line: nil, column: nil)
        }
    }
}
