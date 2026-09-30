//
//  LaTeXJSAssets.swift
//  Pic2PDF
//
//  Serves the bundled latex.js (LatexJS.bundle, MIT, v0.12.6) to web views through a custom
//  `latexjs://` scheme, so rendering and validation work offline.
//

import Foundation
import WebKit
import UniformTypeIdentifiers

enum LaTeXJSAssets {
    static let scheme = "latexjs"
    /// Base URL for pages and for latex.js's `stylesAndScripts(_:)`.
    static let baseURL = URL(string: "\(scheme)://app/")!

    static var bundleURL: URL? {
        Bundle.main.url(forResource: "LatexJS", withExtension: "bundle")
    }

    /// Adds the scheme handler to a configuration. Call before creating the web view.
    static func install(in configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(SchemeHandler(), forURLScheme: scheme)
    }

    private final class SchemeHandler: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, let root = LaTeXJSAssets.bundleURL else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let relative = url.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            let fileURL = root.appendingPathComponent(relative).standardizedFileURL
            // Never serve anything outside the bundle.
            guard fileURL.path.hasPrefix(root.standardizedFileURL.path),
                  let data = try? Data(contentsOf: fileURL) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"])!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }
}
