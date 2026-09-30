//
//  ContentView.swift
//  Pic2PDF
//
//  Created by Younes Laaroussi on 2025-10-13.
//

import SwiftUI
import PhotosUI
import PDFKit
import Combine

struct ContentView: View {
    @StateObject private var mainGenerationViewModel = MainGenerationViewModel()
    @StateObject private var llmService = OnDeviceLLMService.shared
    @State private var selectedTab = ContentView.initialTab

    /// Debug builds can open a tab at launch (PIC2PDF_DEBUG_TAB=0...3) for screenshots and UI checks.
    private static var initialTab: Int {
        #if DEBUG
        return Int(ProcessInfo.processInfo.environment["PIC2PDF_DEBUG_TAB"] ?? "") ?? 0
        #else
        return 0
        #endif
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                MainGenerationView(viewModel: mainGenerationViewModel)
                    .tabItem {
                        Label("Generate", systemImage: "doc.badge.plus")
                    }
                    .tag(0)

                HistoryView()
                    .tabItem {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .tag(1)

                StatsView()
                    .tabItem {
                        Label("Analytics", systemImage: "chart.bar.fill")
                    }
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(3)
            }

            // Covers the tabs while the model works, so nothing else can start meanwhile.
            if mainGenerationViewModel.isGenerating {
                GenerationProgressView(status: mainGenerationViewModel.generationStatus, llmService: llmService)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: mainGenerationViewModel.isGenerating)
    }
}

// View model to share state between ContentView and MainGenerationView
@MainActor
class MainGenerationViewModel: ObservableObject {
    @Published var isGenerating = false
    @Published var generationStatus = GenerationStatus()
}

// MARK: - Main Generation View
struct MainGenerationView: View {
    @ObservedObject var viewModel: MainGenerationViewModel

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage] = []
    @State private var currentLaTeX: String = ""
    @State private var errorMessage: String?
    @State private var refinementFeedback = ""
    @State private var showCamera = false
    @State private var showEditorView = false

    @StateObject private var onDeviceLLMService = OnDeviceLLMService.shared

    @EnvironmentObject var storageManager: StorageManager

    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            Group {
                if selectedImages.isEmpty {
                    emptyState
                } else {
                    imageGrid
                }
            }
            .navigationTitle("Img2Latex")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !selectedImages.isEmpty {
                        Button("Clear", role: .destructive, action: reset)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !selectedImages.isEmpty {
                        if isCameraAvailable {
                            Button {
                                showCamera = true
                            } label: {
                                Label("Take Photo", systemImage: "camera")
                            }
                        }
                        PhotosPicker(selection: $selectedItems, maxSelectionCount: 10, matching: .images) {
                            Label("Choose Photos", systemImage: "photo.on.rectangle")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .navigationDestination(isPresented: $showEditorView) {
                LaTeXPreviewWithActionsView(
                    currentLaTeX: $currentLaTeX,
                    selectedImages: selectedImages,
                    onRefinement: { feedback in
                        showEditorView = false
                        refinementFeedback = feedback
                        refineLaTeX()
                    },
                    onStartOver: {
                        showEditorView = false
                        reset()
                    }
                )
            }
            .sheet(isPresented: $showCamera) {
                CameraView { image in
                    selectedImages.append(image)
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            .onChange(of: selectedItems) { _, newItems in
                Task {
                    await loadImages(from: newItems)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Photos to LaTeX", systemImage: "doc.text.viewfinder")
        } description: {
            Text("Choose or take photos of handwritten math or notes.")
        } actions: {
            PhotosPicker(selection: $selectedItems, maxSelectionCount: 10, matching: .images) {
                Text("Choose Photos")
            }
            .buttonStyle(.borderedProminent)

            if isCameraAvailable {
                Button("Take Photo") {
                    showCamera = true
                }
            }
        }
    }

    private var imageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                ForEach(selectedImages.indices, id: \.self) { index in
                    Color.clear
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .overlay {
                            Image(uiImage: selectedImages[index])
                                .resizable()
                                .scaledToFill()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
    }

    /// Generate button, model status and the SME2 / NEON indicator.
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if let initializationError = onDeviceLLMService.initializationError {
                Text(initializationError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task {
                        await onDeviceLLMService.loadModelIfNeeded(onDeviceLLMService.selectedModel)
                    }
                }
                .buttonStyle(.bordered)
            } else if !onDeviceLLMService.isInitialized {
                ProgressView("Loading AI model…")
            } else if !selectedImages.isEmpty {
                Button(action: generateLaTeX) {
                    Label("Generate LaTeX", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isGenerating)
            }

            if onDeviceLLMService.isInitialized, let mode = onDeviceLLMService.accelerationMode {
                Label("On-device · \(mode.displayName)", systemImage: "cpu")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func loadImages(from items: [PhotosPickerItem]) async {
        selectedImages.removeAll()

        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                selectedImages.append(image)
            }
        }
    }

    private func generateLaTeX() {
        Task {
            viewModel.isGenerating = true
            errorMessage = nil

            do {
                currentLaTeX = try await onDeviceLLMService.generateLaTeX(from: selectedImages, additionalPrompt: nil, status: viewModel.generationStatus)

                // Auto-save to history
                do {
                    let saved = try storageManager.saveGeneration(
                        images: selectedImages,
                        latex: currentLaTeX,
                        pdfDocument: nil,
                        title: nil
                    )
                    storageManager.link(diagnosticsID: onDeviceLLMService.lastDiagnosticsID, to: saved.id)
                } catch {
                    print("[ContentView] Failed to auto-save: \(error)")
                }

                viewModel.isGenerating = false
                showEditorView = true
            } catch {
                errorMessage = error.localizedDescription
                viewModel.isGenerating = false
            }
        }
    }

    private func refineLaTeX() {
        Task {
            viewModel.isGenerating = true
            errorMessage = nil

            do {
                currentLaTeX = try await onDeviceLLMService.refineLaTeX(
                    currentLaTeX: currentLaTeX,
                    userFeedback: refinementFeedback,
                    status: viewModel.generationStatus
                )
                viewModel.isGenerating = false
                showEditorView = true
                refinementFeedback = ""
            } catch {
                errorMessage = error.localizedDescription
                viewModel.isGenerating = false
            }
        }
    }

    private func reset() {
        selectedItems.removeAll()
        selectedImages.removeAll()
        currentLaTeX = ""
        errorMessage = nil
        refinementFeedback = ""
    }
}

// MARK: - Generation Progress

/// Full-screen progress shown over the tabs while the model is generating or refining.
struct GenerationProgressView: View {
    @ObservedObject var status: GenerationStatus
    @ObservedObject var llmService: OnDeviceLLMService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ProgressView(value: status.progress) {
                        Text(status.statusMessage)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Runs entirely on this device. Keep the app open until it finishes.")
                }

                Section("Live") {
                    LabeledContent("Speed", value: speedText)
                    LabeledContent("Memory", value: "\(Int(llmService.currentMemoryUsage)) MB")
                    if let mode = llmService.accelerationMode {
                        LabeledContent("Acceleration", value: mode.displayName)
                    }
                }

                if !llmService.streamingLaTeX.isEmpty {
                    Section("LaTeX") {
                        Text(latexTail)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Generating")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var speedText: String {
        return llmService.currentTokensPerSecond > 0 ? String(format: "%.1f tok/s", llmService.currentTokensPerSecond) : "–"
    }

    /// The last lines of the streamed LaTeX, so the newest output stays in view.
    private var latexTail: String {
        return llmService.streamingLaTeX
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(12)
            .joined(separator: "\n")
    }
}

// MARK: - Refinement

struct RefinementView: View {
    @Binding var feedback: String
    let onSubmit: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("For example: fix the exponent in the second equation", text: $feedback, axis: .vertical)
                        .lineLimit(4...10)
                } footer: {
                    Text("Only the LaTeX is revised; the photos are not processed again.")
                }
            }
            .navigationTitle("Refine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Refine", action: onSubmit)
                        .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Camera

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView

        init(_ parent: CameraView) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(StorageManager.shared)
}
