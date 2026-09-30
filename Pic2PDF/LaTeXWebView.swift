//
//  LaTeXWebView.swift
//  Pic2PDF
//

import SwiftUI
import WebKit
import PDFKit

struct LaTeXWebView: UIViewRepresentable {
    let latex: String
    let onWebViewReady: ((WKWebView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        LaTeXJSAssets.install(in: config)
        config.preferences.javaScriptEnabled = true
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "jsLog")
        controller.add(context.coordinator, name: "renderStatus")
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        print("[LaTeXWebView] makeUIView, latex length=\(latex.count)")
        context.coordinator.load(latex: latex, in: webView)
        DispatchQueue.main.async { onWebViewReady?(webView) }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Re-render only when the LaTeX actually changes (SwiftUI calls this on every view update).
        guard context.coordinator.renderedLatex != latex else { return }
        context.coordinator.load(latex: latex, in: uiView)
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var renderedLatex: String?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "jsLog", let msg = message.body as? String {
                print("[LaTeXWebView][JS] \(msg)")
            } else if message.name == "renderStatus", let msg = message.body as? String {
                print("[LaTeXWebView][Status] \(msg)")
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            print("[LaTeXWebView] didStartProvisionalNavigation")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[LaTeXWebView] didFinish navigation")
        }

        func load(latex: String, in webView: WKWebView) {
            renderedLatex = latex
            print("[LaTeXWebView] load() called, latex length: \(latex.count)")
            print("[LaTeXWebView] First 200 chars of latex: \(String(latex.prefix(200)))")
            
            // STRIP UNSUPPORTED PACKAGES AND COMMANDS
            let cleanedLatex = LaTeXSanitizer.clean(latex)
            print("[LaTeXWebView] After cleaning: \(String(cleanedLatex.prefix(200)))")
            
            // Embed as a JSON string literal: valid JavaScript for any input (\r, U+2028, quotes...).
            // "</" is escaped so the text can never close the <script> element early.
            let jsonArray = (try? JSONSerialization.data(withJSONObject: [cleanedLatex])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let jsString = String(jsonArray.dropFirst().dropLast()).replacingOccurrences(of: "</", with: "<\\/")

            let html = """
            <!DOCTYPE html>
            <html>
              <head>
                <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
                <meta charset=\"UTF-8\">
                <style>
                  body { margin: 12px; background: #fff; }
                </style>
                <script src=\"\(LaTeXJSAssets.baseURL.absoluteString)latex.js\"></script>
              </head>
              <body>
                <script>
                  (function(){
                    try {
                      const src = \(jsString);
                      const generator = new latexjs.HtmlGenerator({ hyphenate: false });
                      latexjs.parse(src, { generator: generator });
                      
                      // Inject styles and scripts using the LaTeX.js base URL
                      document.head.appendChild(generator.stylesAndScripts("\(LaTeXJSAssets.baseURL.absoluteString)"));
                      
                      // Append the generated HTML
                      document.body.appendChild(generator.domFragment());
                      window.webkit.messageHandlers.renderStatus.postMessage("ok text=" + document.body.innerText.trim().length + " html=" + document.body.innerHTML.length);
                    } catch (e) {
                      document.body.innerHTML = '<pre style=\"color:red\">' + e.toString() + '</pre>';
                      window.webkit.messageHandlers.renderStatus.postMessage("error " + e.toString());
                    }
                  })();
                </script>
              </body>
            </html>
            """
            
            print("[LaTeXWebView] ========== INJECTED HTML START ==========")
            print(html)
            print("[LaTeXWebView] ========== INJECTED HTML END ==========")

            webView.loadHTMLString(html, baseURL: LaTeXJSAssets.baseURL)
        }
        
    }
}

extension WKWebView {
    func exportPDF(completion: @escaping (Result<Data, Error>) -> Void) {
        let config = WKPDFConfiguration()
        self.createPDF(configuration: config) { result in
            switch result {
            case .success(let data): completion(.success(data))
            case .failure(let error): completion(.failure(error))
            }
        }
    }
}
