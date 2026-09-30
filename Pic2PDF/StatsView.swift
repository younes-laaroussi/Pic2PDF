//
//  StatsView.swift
//  Pic2PDF
//
//  Created by AI Assistant on 2025-01-30.
//

import SwiftUI
import Charts
import UIKit

struct StatsView: View {
    @StateObject private var llmService = OnDeviceLLMService.shared

    /// The most recent generations, enough for a readable chart.
    private var recentMetrics: [GenerationMetrics] {
        Array(llmService.generationHistory.suffix(20))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("This Session") {
                    LabeledContent("Generations", value: "\(llmService.totalGenerations)")
                    LabeledContent("Average time", value: String(format: "%.1f s", llmService.averageGenerationTime))
                    LabeledContent("Average speed", value: String(format: "%.1f tok/s", llmService.averageTokensPerSecond))
                    LabeledContent("Tokens generated", value: "\(llmService.totalTokensGenerated)")
                    LabeledContent("Peak memory", value: String(format: "%.0f MB", llmService.peakMemoryUsage))
                }

                if !recentMetrics.isEmpty {
                    Section("Generation Time") {
                        Chart(recentMetrics) { metric in
                            LineMark(
                                x: .value("Time", metric.timestamp),
                                y: .value("Seconds", metric.generationTime)
                            )
                            .symbol(.circle)
                        }
                        .chartYAxisLabel("s")
                        .frame(height: 160)
                    }

                    Section("Speed") {
                        Chart(recentMetrics) { metric in
                            LineMark(
                                x: .value("Time", metric.timestamp),
                                y: .value("Tokens per second", metric.tokensPerSecond)
                            )
                            .symbol(.circle)
                        }
                        .chartYAxisLabel("tok/s")
                        .frame(height: 160)
                    }
                }

                Section("Now") {
                    LabeledContent("Memory", value: "\(Int(llmService.currentMemoryUsage)) MB")
                    LabeledContent("Thermal state", value: ProcessMetrics.thermalStateDescription(llmService.thermalState))
                    LabeledContent("Battery", value: "\(llmService.batteryLevel)%")
                }

                Section("Model & System") {
                    LabeledContent("Model", value: llmService.currentModelInfo.isInitialized ? llmService.currentModelInfo.identifier.displayName : "Not loaded")
                    LabeledContent("Load time", value: String(format: "%.1f s", llmService.modelInitializationTime))
                    LabeledContent("Acceleration", value: llmService.accelerationMode?.displayName ?? (llmService.isInitialized ? "Unknown" : "Not loaded"))
                    LabeledContent("CPU supports SME2", value: SME2Support.isSupported ? "Yes" : "No")
                    LabeledContent("Device", value: SME2Benchmark.deviceModelIdentifier())
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                }

                Section {
                    NavigationLink {
                        BenchmarkView()
                    } label: {
                        Label("SME2 Benchmark", systemImage: "stopwatch")
                    }
                } footer: {
                    Text("Compare SME2 and NEON on this device.")
                }
            }
            .navigationTitle("Analytics")
        }
    }
}

#Preview {
    StatsView()
}
