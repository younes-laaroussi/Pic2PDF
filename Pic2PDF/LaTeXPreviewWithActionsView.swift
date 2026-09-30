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
    @State private var copied = false
    @ObservedObject private var llmService = OnDeviceLLMService.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        LaTeXWebView(latex: currentLaTeX) { view in
            webView = view
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let run = llmService.lastRun, run.succeeded {
                RunSummaryBar(run: run)
            }
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

                Button {
                    UIPasteboard.general.string = currentLaTeX
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy LaTeX", systemImage: copied ? "checkmark" : "doc.on.doc")
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

/// One-line summary of the run that produced the preview; opens the full diagnostics.
private struct RunSummaryBar: View {
    let run: RunDiagnostics

    var body: some View {
        NavigationLink {
            RunDiagnosticsDetailView(run: run)
        } label: {
            HStack(spacing: 12) {
                metric(String(format: "%.1f s", run.timeToFirstTokenSeconds), "first token")
                metric(String(format: "%.1f", run.decodeTokensPerSecond), "tok/s")
                metric(String(format: "%.1f s", run.totalSeconds), "total")
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(run.acceleration)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(run.acceleration == "SME2" ? Color.accentColor : .secondary)
                    Text(fixSummary)
                        .font(.caption2)
                        .foregroundStyle(run.fixRemainingError == nil ? Color.secondary : Color.orange)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .buttonStyle(.plain)
    }

    private var fixSummary: String {
        if run.fixRemainingError != nil { return "LaTeX has an error" }
        if run.usedModelRepair { return "Fixed by the model" }
        if run.fixSteps.isEmpty { return "LaTeX OK" }
        return "\(run.fixSteps.count) fix\(run.fixSteps.count == 1 ? "" : "es") applied"
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
