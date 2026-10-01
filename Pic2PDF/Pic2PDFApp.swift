//
//  Pic2PDFApp.swift
//  Pic2PDF
//
//  Created by Younes Laaroussi on 2025-10-13.
//

import SwiftUI
import SwiftData

@main
struct Pic2PDFApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var storageManager = StorageManager.shared
    
    init() {
        SettingsKey.registerDefaults()
        // XNNPACK reads its SME2 gate once, on first init inside the model load,
        // so set it before any view touches OnDeviceLLMService.shared.
        SME2Support.configureBeforeModelLoad()
        #if DEBUG
        DebugAutoGenerate.startIfRequested()
        DebugAutoGenerate.latexSelfTestIfRequested()
        DebugAutoGenerate.resetAndBenchmarkIfRequested()
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if DebugAutoGenerateState.shared.latex != nil || ProcessInfo.processInfo.environment["PIC2PDF_AUTOGEN_SHOW_PREVIEW"] == "1" {
                    DebugPreviewHost()
                } else if ProcessInfo.processInfo.environment["PIC2PDF_DEBUG_BENCH_VIEW"] == "1" {
                    NavigationStack { BenchmarkView() }
                } else if let sample = DebugAutoGenerate.previewSample {
                    LaTeXWebView(latex: sample, onWebViewReady: nil).ignoresSafeArea()
                } else if appState.showOnboarding {
                    OnboardingView()
                        .environmentObject(appState)
                } else {
                    ContentView()
                        .environmentObject(storageManager)
                        .environmentObject(appState)
                        .modelContainer(storageManager.modelContainer)
                }
            }
            .preferredColorScheme(DebugAutoGenerate.forcedScheme)
        }
    }
}

#if DEBUG
private struct DebugPreviewHost: View {
    @ObservedObject var state = DebugAutoGenerateState.shared
    @State private var latex = ""
    var body: some View {
        NavigationStack {
            if state.latex != nil {
                LaTeXPreviewWithActionsView(currentLaTeX: $latex, selectedImages: [], onRefinement: { _ in }, onStartOver: {})
                    .onAppear { latex = state.latex ?? "" }
            } else {
                ProgressView("Generating…")
            }
        }
    }
}
#endif
