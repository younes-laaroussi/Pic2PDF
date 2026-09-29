//
//  OnboardingView.swift
//  Pic2PDF
//
//  Created for Arm AI Developer Challenge 2025
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @State private var selectedModel: ModelIdentifier = .gemma2B
    @State private var downloadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Welcome to Img2Latex")
                    .font(.largeTitle.bold())
                    .padding(.top, 40)

                VStack(alignment: .leading, spacing: 24) {
                    feature("doc.text.viewfinder", title: "Photos to LaTeX", text: "Turn handwritten math and notes into LaTeX and PDF.")
                    feature("lock.shield", title: "Private", text: "The AI runs on your iPhone. Your photos never leave it.")
                    feature("cpu", title: "Built for Arm", text: "Uses SME2 on A18 and M4-class chips, and NEON on older ones.")
                    feature("wand.and.stars", title: "Refine and Share", text: "Ask for changes, then share the result as a PDF.")
                }

                modelSection
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                withAnimation {
                    appState.completeOnboarding()
                }
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
    }

    private func feature(_ systemImage: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Model Download

    private var modelSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(ModelIdentifier.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(downloadManager.downloadStatus.isInProgress)

                Text(modelDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                downloadStatus
            }
        } label: {
            Label("AI Model", systemImage: "arrow.down.circle")
        }
    }

    @ViewBuilder
    private var downloadStatus: some View {
        if downloadManager.isModelDownloaded(selectedModel) {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            switch downloadManager.downloadStatus {
            case .downloading(let progress, let downloaded, let total):
                ProgressView(value: progress) {
                    Text("Downloading…")
                } currentValueLabel: {
                    Text("\(formatBytes(downloaded)) of \(formatBytes(total))")
                }
                Button("Cancel", role: .cancel) {
                    downloadManager.cancelDownload()
                }
            case .verifying, .extracting:
                ProgressView("Setting up…")
            default:
                if let downloadError = downloadError {
                    Text(downloadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    startDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                Text("You can also download it later in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelDescription: String {
        let size = DownloadableModelConfig.availableModels[selectedModel].map { formatBytes(Int64($0.expectedSizeMB * 1024 * 1024)) } ?? ""
        switch selectedModel {
        case .gemma2B:
            return "\(size) download. Faster; good for most notes."
        case .gemma4B:
            return "\(size) download. Slower; best accuracy."
        }
    }

    private func startDownload() {
        downloadError = nil
        Task {
            do {
                try await downloadManager.downloadModel(selectedModel)
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState.shared)
}
