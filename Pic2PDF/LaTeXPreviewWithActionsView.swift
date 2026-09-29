//
//  LaTeXPreviewWithActionsView.swift
//  Pic2PDF
//

import SwiftUI
import PDFKit
import WebKit

struct LaTeXPreviewWithActionsView: View {
    @Binding var currentLaTeX: String
    let selectedImages: [UIImage]
    let onRefinement: (String) -> Void
    let onStartOver: () -> Void

    @State private var showRefinementSheet = false
    @State private var refinementFeedback = ""
    @State private var webView: WKWebView?
    @State private var isExporting = false
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        LaTeXWebView(latex: currentLaTeX) { view in
            webView = view
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    showRefinementSheet = true
                } label: {
                    Label("Refine", systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                }

                Spacer()

                Button(action: sharePDF) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)
            }
        }
        .sheet(isPresented: $showRefinementSheet) {
            RefinementView(
                feedback: $refinementFeedback,
                onSubmit: {
                    showRefinementSheet = false
                    dismiss()
                    onRefinement(refinementFeedback)
                }
            )
        }
        .sheet(isPresented: $showShareSheet) {
            if let shareURL = shareURL {
                ShareSheet(items: [shareURL])
            }
        }
    }

    private func exportPDF(completion: @escaping (Result<Data, Error>) -> Void) {
        guard let webView = webView else { return }
        isExporting = true
        webView.exportPDF { result in
            isExporting = false
            completion(result)
        }
    }

    private func sharePDF() {
        exportPDF { result in
            switch result {
            case .success(let data):
                let fileName = "Pic2PDF_\(Date().timeIntervalSince1970).pdf"
                let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                do {
                    try data.write(to: temporaryURL)
                    DispatchQueue.main.async {
                        shareURL = temporaryURL
                        showShareSheet = true
                    }
                } catch {
                    print("[Preview] Share write failed: \(error)")
                }
            case .failure(let error):
                print("[Preview] Export failed: \(error)")
            }
        }
    }
}
