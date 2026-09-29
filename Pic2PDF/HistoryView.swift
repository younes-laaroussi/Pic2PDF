//
//  HistoryView.swift
//  Pic2PDF
//
//  Created by Younes Laaroussi on 2025-10-13.
//

import SwiftUI
import PDFKit
import WebKit

struct HistoryView: View {
    @StateObject private var storageManager = StorageManager.shared
    @State private var searchQuery = ""
    @State private var showFavoritesOnly = false
    @State private var showClearAlert = false

    private var filteredGenerations: [Generation] {
        let generations = showFavoritesOnly ? storageManager.favoriteGenerations : storageManager.generations
        guard !searchQuery.isEmpty else { return generations }
        return generations.filter { generation in
            generation.displayTitle.localizedCaseInsensitiveContains(searchQuery) ||
            generation.latex.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredGenerations, id: \.id) { generation in
                    NavigationLink {
                        GenerationDetailView(generation: generation)
                    } label: {
                        GenerationRow(generation: generation)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            try? storageManager.deleteGeneration(generation)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            try? storageManager.toggleFavorite(generation)
                        } label: {
                            Label(generation.isFavorite ? "Unfavorite" : "Favorite",
                                  systemImage: generation.isFavorite ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                }
            }
            .overlay {
                if filteredGenerations.isEmpty {
                    if !searchQuery.isEmpty {
                        ContentUnavailableView.search(text: searchQuery)
                    } else if showFavoritesOnly {
                        ContentUnavailableView("No Favorites", systemImage: "star", description: Text("Swipe right on a document to add it to your favorites."))
                    } else {
                        ContentUnavailableView("No History", systemImage: "clock", description: Text("Documents you generate appear here."))
                    }
                }
            }
            .searchable(text: $searchQuery)
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle(isOn: $showFavoritesOnly) {
                            Label("Favorites Only", systemImage: "star")
                        }
                        Button(role: .destructive) {
                            showClearAlert = true
                        } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                        .disabled(storageManager.generations.isEmpty)
                    } label: {
                        Label("Options", systemImage: "ellipsis.circle")
                    }
                }
            }
            .alert("Clear History?", isPresented: $showClearAlert) {
                Button("Clear", role: .destructive) {
                    try? storageManager.clearAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes all saved documents and can't be undone.")
            }
        }
    }
}

private struct GenerationRow: View {
    let generation: Generation

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(generation.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if generation.isFavorite {
                Spacer()
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .imageScale(.small)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = generation.imageDataArray.first, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 58)
        }
    }

    private var subtitle: String {
        let images = generation.imageCount == 1 ? "1 image" : "\(generation.imageCount) images"
        let refinementCount = generation.refinementHistory.count
        guard refinementCount > 0 else { return images }
        let refinements = refinementCount == 1 ? "1 refinement" : "\(refinementCount) refinements"
        return "\(images) · \(refinements)"
    }
}

struct GenerationDetailView: View {
    let generation: Generation
    @State private var webView: WKWebView?
    @State private var shareURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        List {
            Section {
                LaTeXWebView(latex: generation.latex) { view in
                    webView = view
                }
                .frame(height: 420)
                .listRowInsets(EdgeInsets())
            }

            Section("Details") {
                LabeledContent("Created", value: generation.timestamp.formatted(date: .long, time: .shortened))
                LabeledContent("Images", value: "\(generation.imageCount)")
                if !generation.refinementHistory.isEmpty {
                    LabeledContent("Refinements", value: "\(generation.refinementHistory.count)")
                }
            }

            if !generation.imageDataArray.isEmpty {
                Section("Photos") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(generation.getImages(), id: \.self) { image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 90, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }

            Section("LaTeX") {
                Text(generation.latex)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            if !generation.refinementHistory.isEmpty {
                Section("Refinements") {
                    ForEach(generation.refinementHistory.indices, id: \.self) { index in
                        let refinement = generation.refinementHistory[index]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(refinement.feedback)
                            Text(refinement.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(generation.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: shareAsPDF) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let shareURL = shareURL {
                ShareSheet(items: [shareURL])
            }
        }
    }

    private func shareAsPDF() {
        guard let webView = webView else { return }
        webView.exportPDF { result in
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
                    print("[History] Share write failed: \(error)")
                }
            case .failure(let error):
                print("[History] Export failed: \(error)")
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    HistoryView()
}
