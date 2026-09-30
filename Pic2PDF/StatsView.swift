//
//  StatsView.swift
//  Pic2PDF
//
//  Analytics built from the saved per-run diagnostics, so history survives app restarts.
//

import SwiftUI
import Charts
import UIKit

struct StatsView: View {
    @StateObject private var llmService = OnDeviceLLMService.shared
    @EnvironmentObject private var storage: StorageManager
    @State private var confirmClear = false

    private var runs: [RunDiagnostics] { storage.diagnostics }
    private var succeeded: [RunDiagnostics] { runs.filter(\.succeeded) }
    /// Oldest first, for charts.
    private var chartRuns: [RunDiagnostics] { Array(succeeded.prefix(40).reversed()) }

    var body: some View {
        NavigationStack {
            List {
                if runs.isEmpty {
                    Section {
                        ContentUnavailableView("No runs yet",
                                               systemImage: "chart.xyaxis.line",
                                               description: Text("Generate LaTeX from a photo and each run's timing, memory and LaTeX checks show up here."))
                    }
                } else {
                    summarySection
                    accelerationSection
                    chartsSection
                    fixesSection
                    recentRunsSection
                    exportSection
                }

                Section("Now") {
                    LabeledContent("Memory", value: String(format: "%.0f MB", ProcessMetrics.currentFootprintMB()))
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
                    Text("Compare SME2 and NEON on this device with a fixed sample image.")
                }
            }
            .navigationTitle("Analytics")
            .confirmationDialog("Delete all saved run diagnostics?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete Diagnostics", role: .destructive) { storage.deleteAllDiagnostics() }
            }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section("All Runs") {
            LabeledContent("Runs", value: "\(runs.count)")
            LabeledContent("Succeeded", value: "\(succeeded.count) of \(runs.count)")
            LabeledContent("Median time to first token", value: format(median(succeeded.map(\.timeToFirstTokenSeconds)), "%.2f s"))
            LabeledContent("Median decode speed", value: format(median(succeeded.map(\.decodeTokensPerSecond)), "%.1f tok/s"))
            LabeledContent("Median total time", value: format(median(succeeded.map(\.totalSeconds)), "%.1f s"))
            LabeledContent("Median peak memory", value: format(median(succeeded.map(\.peakMemoryMB)), "%.0f MB"))
        }
    }

    @ViewBuilder
    private var accelerationSection: some View {
        let sme2 = succeeded.filter { $0.acceleration == "SME2" && $0.kind == "generate" }
        let neon = succeeded.filter { $0.acceleration == "NEON" && $0.kind == "generate" }
        if !sme2.isEmpty && !neon.isEmpty {
            Section {
                comparisonRow("Time to first token", sme2.map(\.timeToFirstTokenSeconds), neon.map(\.timeToFirstTokenSeconds), "%.2f s", lowerIsBetter: true)
                comparisonRow("Decode speed", sme2.map(\.decodeTokensPerSecond), neon.map(\.decodeTokensPerSecond), "%.1f tok/s", lowerIsBetter: false)
                comparisonRow("Total time", sme2.map(\.totalSeconds), neon.map(\.totalSeconds), "%.1f s", lowerIsBetter: true)
            } header: {
                Text("SME2 vs NEON")
            } footer: {
                Text("Medians of your own generations: \(sme2.count) with SME2, \(neon.count) with NEON. Photos differ between runs, so the SME2 Benchmark below is the controlled comparison.")
            }
        }
    }

    private var chartsSection: some View {
        Group {
            Section("Time to First Token") {
                runChart(\.timeToFirstTokenSeconds, unit: "s")
            }
            Section("Decode Speed") {
                runChart(\.decodeTokensPerSecond, unit: "tok/s")
            }
            Section("Peak Memory") {
                runChart(\.peakMemoryMB, unit: "MB")
            }
        }
    }

    @ViewBuilder
    private var fixesSection: some View {
        let generated = runs.filter { $0.kind == "generate" && $0.succeeded }
        if !generated.isEmpty {
            let fixed = generated.filter { !$0.fixSteps.isEmpty }
            let modelRepaired = generated.filter(\.usedModelRepair)
            let unresolved = generated.filter { $0.fixRemainingError != nil }
            Section {
                LabeledContent("Needed fixes", value: "\(fixed.count) of \(generated.count)")
                LabeledContent("Fixed by the model", value: "\(modelRepaired.count)")
                LabeledContent("Still invalid", value: "\(unresolved.count)")
            } header: {
                Text("LaTeX Checks")
            } footer: {
                Text("Every result is checked with latex.js before it's shown, and repaired if it wouldn't render.")
            }
        }
    }

    private var recentRunsSection: some View {
        Section("Recent Runs") {
            ForEach(runs.prefix(15)) { run in
                NavigationLink {
                    RunDiagnosticsDetailView(run: run)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(run.kind == "refine" ? "Refinement" : "Generation")
                            Spacer()
                            Text(run.acceleration)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(run.acceleration == "SME2" ? Color.accentColor : .secondary)
                        }
                        Text(run.succeeded
                             ? String(format: "%.2f s to first token · %.1f tok/s · %.1f s total", run.timeToFirstTokenSeconds, run.decodeTokensPerSecond, run.totalSeconds)
                             : "Failed: \(run.errorMessage ?? "unknown error")")
                            .font(.caption)
                            .foregroundStyle(run.succeeded ? Color.secondary : Color.red)
                        Text(run.timestamp, format: .dateTime.month().day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var exportSection: some View {
        Section {
            ShareLink(item: DiagnosticsExport.file(for: runs, format: .csv), preview: SharePreview("Run diagnostics (CSV)")) {
                Label("Export CSV", systemImage: "tablecells")
            }
            ShareLink(item: DiagnosticsExport.file(for: runs, format: .json), preview: SharePreview("Run diagnostics (JSON)")) {
                Label("Export JSON", systemImage: "curlybraces")
            }
            Button("Delete Diagnostics", role: .destructive) { confirmClear = true }
        } footer: {
            Text("Diagnostics stay on this device unless you export them.")
        }
    }

    // MARK: - Helpers

    private func runChart(_ value: KeyPath<RunDiagnostics, Double>, unit: String) -> some View {
        Chart(chartRuns) { run in
            PointMark(x: .value("Run", run.timestamp), y: .value(unit, run[keyPath: value]))
                .foregroundStyle(by: .value("Acceleration", run.acceleration))
        }
        .chartForegroundStyleScale(["SME2": Color.accentColor, "NEON": Color.gray, "Unknown": Color.orange])
        .chartYAxisLabel(unit)
        .frame(height: 170)
    }

    private func comparisonRow(_ title: String, _ sme2: [Double], _ neon: [Double], _ fmt: String, lowerIsBetter: Bool) -> some View {
        let a = median(sme2), b = median(neon)
        let change = (a != nil && b != nil && b! != 0) ? (a! - b!) / b! * 100 : nil
        return LabeledContent {
            VStack(alignment: .trailing) {
                Text("\(format(a, fmt)) vs \(format(b, fmt))")
                if let change {
                    let better = lowerIsBetter ? change < 0 : change > 0
                    Text(String(format: "%+.0f%%", change))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(better ? .green : .orange)
                }
            }
        } label: {
            Text(title)
        }
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private func format(_ value: Double?, _ fmt: String) -> String {
        value.map { String(format: fmt, $0) } ?? "—"
    }
}

#Preview {
    StatsView()
        .environmentObject(StorageManager.shared)
}
