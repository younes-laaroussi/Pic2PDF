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
        // XNNPACK reads its SME2 gate once, on first init inside the model load,
        // so set it before any view touches OnDeviceLLMService.shared.
        SME2Support.configureBeforeModelLoad()
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if appState.showOnboarding {
                    OnboardingView()
                        .environmentObject(appState)
                } else {
                    ContentView()
                        .environmentObject(storageManager)
                        .environmentObject(appState)
                        .modelContainer(storageManager.modelContainer)
                }
            }
        }
    }
}
