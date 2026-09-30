//
//  SettingsView.swift
//  Pic2PDF
//
//  Created by Younes Laaroussi on 2025-10-13.
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var storageManager = StorageManager.shared
    @StateObject private var appState = AppState.shared
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @StateObject private var llmService = OnDeviceLLMService.shared
    @AppStorage("performanceModeEnabled") private var performanceModeEnabled = false
    @AppStorage("sme2Enabled") private var sme2Enabled = true
    #if DEBUG
    @AppStorage("debugForceNoSME2") private var debugForceNoSME2 = false
    #endif

    // LLM Parameters (used when refining)
    @AppStorage("llmTemperature") private var temperature: Double = 0.7
    @AppStorage("llmTopP") private var topP: Double = 0.9
    @AppStorage("llmTopK") private var topK: Int = 40
    @AppStorage("llmMaxTokens") private var maxTokens: Int = 2000
    @AppStorage(SettingsKey.imageMaxDimension) private var imageMaxDimension = 768
    @AppStorage(SettingsKey.latexAutoFix) private var latexAutoFix = true
    @AppStorage(SettingsKey.latexModelRepair) private var latexModelRepair = true
    @AppStorage(SettingsKey.keepDiagnostics) private var keepDiagnostics = true
    @State private var showClearDiagnosticsAlert = false

    @State private var showClearDataAlert = false
    @State private var downloadingModel: ModelIdentifier?

    var body: some View {
        NavigationStack {
            Form {
                // SME2 is chosen once per launch (XNNPACK locks it on first model load), so changes need a restart.
                Section {
                    Toggle("Arm SME2", isOn: SME2Support.isSupported ? $sme2Enabled : Binding.constant(false))
                        .disabled(!SME2Support.isSupported)
                    if let mode = llmService.accelerationMode {
                        LabeledContent("Running on", value: mode.displayName)
                    }
                } header: {
                    Text("Acceleration")
                } footer: {
                    Text(sme2Footer)
                }

                #if DEBUG
                Section {
                    Toggle("Simulate device without SME2", isOn: $debugForceNoSME2)
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Treats this device as unsupported to test the NEON fallback. Takes effect after a restart.")
                }
                #endif

                Section {
                    Toggle("Performance Mode", isOn: $performanceModeEnabled)
                } footer: {
                    Text("Smaller images and shorter output for faster results.")
                }

                Section {
                    Picker("Image detail", selection: $imageMaxDimension) {
                        Text("Fast (512 px)").tag(512)
                        Text("Balanced (768 px)").tag(768)
                        Text("Detailed (1024 px)").tag(1024)
                    }
                    .disabled(performanceModeEnabled)
                    Toggle("Check and fix LaTeX", isOn: $latexAutoFix)
                    Toggle("Let the model fix errors", isOn: $latexModelRepair)
                        .disabled(!latexAutoFix)
                } header: {
                    Text("Transcription")
                } footer: {
                    Text(performanceModeEnabled
                         ? "Performance Mode uses 512 px images. Results are checked with latex.js, the same library that renders them; if a result wouldn't render, the app repairs it, and can ask the model to fix the exact error."
                         : "768 px is the vision encoder's native size; 1024 px keeps more detail for dense pages but takes longer. Results are checked with latex.js, the same library that renders them; if a result wouldn't render, the app repairs it, and can ask the model to fix the exact error.")
                }

                Section {
                    VStack(alignment: .leading) {
                        LabeledContent("Temperature", value: temperature, format: .number.precision(.fractionLength(2)))
                        Slider(value: $temperature, in: 0.1...1.5, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Top P", value: topP, format: .number.precision(.fractionLength(2)))
                        Slider(value: $topP, in: 0.1...1.0, step: 0.05)
                    }
                    Stepper("Top K: \(topK)", value: $topK, in: 1...100)
                    Stepper("Max Tokens: \(maxTokens)", value: $maxTokens, in: 500...4000, step: 100)
                    Button("Reset to Defaults", action: resetLLMParameters)
                } header: {
                    Text("Refinement")
                } footer: {
                    Text("Transcription always uses greedy decoding, so the same photo gives the same LaTeX. Temperature, Top P and Top K apply when you refine. Max Tokens applies after the model reloads.")
                }

                Section {
                    if ModelIdentifier.allCases.contains(where: { downloadManager.isModelDownloaded($0) }) {
                        Picker("Current Model", selection: Binding(
                            get: { llmService.selectedModel },
                            set: { newModel in
                                Task {
                                    await llmService.switchModel(to: newModel)
                                }
                            }
                        )) {
                            ForEach(ModelIdentifier.allCases.filter { downloadManager.isModelDownloaded($0) }) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                    }
                    ForEach(ModelIdentifier.allCases) { model in
                        modelRow(model)
                    }
                } header: {
                    Text("AI Model")
                } footer: {
                    Text("Models are downloaded once and stay on this device.")
                }

                Section("Storage") {
                    let stats = storageManager.getStatistics()
                    LabeledContent("Documents", value: "\(stats.totalGenerations)")
                    LabeledContent("Images", value: "\(stats.totalImages)")
                    LabeledContent("Favorites", value: "\(stats.totalFavorites)")
                    LabeledContent("Space Used", value: stats.formattedStorage)
                    Button("Clear All Data", role: .destructive) {
                        showClearDataAlert = true
                    }
                }

                Section {
                    Toggle("Save run diagnostics", isOn: $keepDiagnostics)
                    LabeledContent("Saved runs", value: "\(storageManager.diagnostics.count)")
                    if !storageManager.diagnostics.isEmpty {
                        ShareLink(item: DiagnosticsExport.file(for: storageManager.diagnostics, format: .csv),
                                  preview: SharePreview("Run diagnostics (CSV)")) {
                            Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                        }
                        Button("Delete Diagnostics", role: .destructive) {
                            showClearDiagnosticsAlert = true
                        }
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Timing, memory, acceleration and LaTeX checks for each run, shown in Analytics. Stays on this device unless you export it.")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    Button("Show Welcome Screen") {
                        withAnimation {
                            appState.restartOnboarding()
                        }
                    }
                    Link("GitHub Repository", destination: URL(string: "https://github.com/younes-laaroussi/Pic2PDF")!)
                    Link("Privacy Policy", destination: URL(string: "https://github.com/younes-laaroussi/Pic2PDF/blob/main/PRIVACY.md")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("Built for the Arm AI Developer Challenge 2025. All processing happens on this device.")
                }
            }
            .navigationTitle("Settings")
            .alert("Delete Diagnostics?", isPresented: $showClearDiagnosticsAlert) {
                Button("Delete", role: .destructive) { storageManager.deleteAllDiagnostics() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the saved timing and memory data for all runs. Your documents are kept.")
            }
            .alert("Clear All Data?", isPresented: $showClearDataAlert) {
                Button("Delete All", role: .destructive) {
                    clearAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes all saved documents and can't be undone.")
            }
        }
    }

    private var sme2Footer: String {
        if !SME2Support.isSupported {
            return "Not supported on this device (needs A18 / M4 or newer)."
        }
        if SME2Support.needsRestart {
            return "Restart Img2Latex to apply."
        }
        return "Runs the language model on the CPU's SME2 matrix units. Turn off to use NEON."
    }

    private var appVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    @ViewBuilder
    private func modelRow(_ model: ModelIdentifier) -> some View {
        if downloadManager.isModelDownloaded(model) {
            LabeledContent(model.displayName, value: downloadedSize(model))
        } else if let progress = downloadProgress(for: model) {
            ProgressView(value: progress) {
                Text(model.displayName)
            } currentValueLabel: {
                Text(progress, format: .percent.precision(.fractionLength(0)))
            }
        } else {
            LabeledContent(model.displayName) {
                Button("Download") {
                    download(model)
                }
                .disabled(downloadManager.downloadStatus.isInProgress)
            }
        }
    }

    private func downloadedSize(_ model: ModelIdentifier) -> String {
        guard let sizeMB = downloadManager.modelSize(model) else { return "Downloaded" }
        return String(format: "%.1f GB", sizeMB / 1024)
    }

    private func downloadProgress(for model: ModelIdentifier) -> Double? {
        guard downloadingModel == model, case .downloading(let progress, _, _) = downloadManager.downloadStatus else {
            return nil
        }
        return progress
    }

    private func download(_ model: ModelIdentifier) {
        downloadingModel = model
        Task {
            do {
                try await downloadManager.downloadModel(model)
                await llmService.loadModelIfNeeded(model)
            } catch {
                print("[Settings] Failed to download model: \(error)")
            }
            downloadingModel = nil
        }
    }

    private func clearAllData() {
        do {
            try storageManager.clearAllData()
        } catch {
            print("[Settings] ERROR: Failed to clear data: \(error)")
        }
    }

    private func resetLLMParameters() {
        temperature = 0.7
        topP = 0.9
        topK = 40
        maxTokens = 2000
    }
}

#Preview {
    SettingsView()
}
