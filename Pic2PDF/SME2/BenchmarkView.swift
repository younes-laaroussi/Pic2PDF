//
//  BenchmarkView.swift
//  Pic2PDF
//
//  SME2 vs NEON benchmark screen, reached from the Analytics tab.
//  Runs on the already-loaded model; results stay on this device.
//

import SwiftUI

struct BenchmarkView: View {
    @StateObject private var llmService = OnDeviceLLMService.shared
    @StateObject private var runner = SME2BenchmarkRunner.shared

    private var isBusy: Bool {
        runner.isRunning || llmService.isBenchmarking || llmService.isGenerating
    }

    private var canRun: Bool {
        llmService.isInitialized && !isBusy
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("SME2 vs NEON")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Times the same photo and prompt on your device. Nothing leaves your device.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
                .padding(.horizontal)

                InfoSection(title: "This Launch") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Running on")
                                .foregroundColor(.secondary)
                            Spacer()
                            if let mode = llmService.accelerationMode {
                                AccelerationBadge(mode: mode)
                            } else {
                                Text(llmService.isInitialized ? "Unknown" : "Not loaded")
                                    .fontWeight(.medium)
                            }
                        }
                        .font(.subheadline)
                        InfoRow(label: "CPU supports SME2", value: SME2Support.isSupported ? "Yes" : "No")
                        InfoRow(label: "Runs", value: "1 warm-up + \(SME2Benchmark.measuredRuns) measured")
                    }
                }

                // Run button and status
                VStack(spacing: 12) {
                    Button(action: runBenchmark) {
                        HStack(spacing: 10) {
                            if isBusy {
                                ProgressView()
                            } else {
                                Image(systemName: "stopwatch")
                                    .font(.system(size: 20, weight: .semibold))
                            }
                            Text(isBusy ? "Running..." : "Run Benchmark")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(.systemGray6))
                        .foregroundColor(canRun ? .primary : .secondary)
                        .cornerRadius(16)
                    }
                    .disabled(!canRun)

                    if runner.isRunning {
                        Text("\(runner.statusMessage) This takes about a minute; keep the app open.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else if !llmService.isInitialized {
                        Text("Waiting for the AI model to load.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let error = runner.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)

                resultsSection

                // What is measured
                VStack(alignment: .leading, spacing: 6) {
                    Text("First token: generate call to the first streamed token (prompt and image prefill).")
                    Text("Decode: tokens after the first, divided by the time after the first token.")
                    Text("Total: image added to the last token. Session setup is not counted.")
                    Text("Each value is the median of \(SME2Benchmark.measuredRuns) runs after a warm-up, with greedy decoding on the same photo and prompt.")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
            .padding(.bottom, 20)
        }
        .navigationTitle("SME2 Benchmark")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if let sme2 = runner.results[.sme2], let neon = runner.results[.neon] {
            InfoSection(title: "SME2 vs NEON") {
                VStack(alignment: .leading, spacing: 12) {
                    ComparisonTable(neon: neon, sme2: sme2)
                    if sme2.modelName != neon.modelName {
                        Text("These results used different models. Run both modes again with the same model to compare.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    ResultFootnote(result: neon)
                    ResultFootnote(result: sme2)
                }
            }
        } else if let result = singleResult {
            InfoSection(title: "\(result.mode.displayName) Result") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(BenchmarkMetric.all) { metric in
                        InfoRow(label: metric.name, value: metric.formatted(result))
                    }
                    InfoRow(label: "Output tokens", value: "\(result.outputTokens)")
                    InfoRow(label: "Thermal state", value: result.thermalState)
                    ResultFootnote(result: result)
                }
            }

            Text(compareHint(missing: result.mode == .sme2 ? .neon : .sme2))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        } else {
            Text("No results yet. Run the benchmark to measure this mode.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    /// The current mode's result if there is one, otherwise whichever result exists.
    private var singleResult: SME2BenchmarkResult? {
        if let mode = llmService.accelerationMode, let result = runner.results[mode] {
            return result
        }
        return runner.results[.sme2] ?? runner.results[.neon]
    }

    private func compareHint(missing: SME2Support.Mode) -> String {
        if missing == .sme2 && !SME2Support.isSupported {
            return "This device doesn't support SME2, so only NEON can be measured."
        }
        if llmService.accelerationMode == missing {
            return "Run the benchmark now to add the \(missing.displayName) result."
        }
        return missing == .neon
            ? "Switch SME2 off in Settings, restart, and run again to compare."
            : "Switch SME2 on in Settings, restart, and run again to compare."
    }

    private func runBenchmark() {
        Task {
            await runner.run(on: llmService)
        }
    }
}

// MARK: - Supporting Views

private struct BenchmarkMetric: Identifiable {
    let name: String
    let format: String
    let lowerIsBetter: Bool
    let value: (SME2BenchmarkResult) -> Double

    var id: String { name }

    func formatted(_ result: SME2BenchmarkResult) -> String {
        return String(format: format, value(result))
    }

    static let all: [BenchmarkMetric] = [
        BenchmarkMetric(name: "First token", format: "%.2f s", lowerIsBetter: true) { $0.timeToFirstTokenSeconds },
        BenchmarkMetric(name: "Decode", format: "%.1f tok/s", lowerIsBetter: false) { $0.decodeTokensPerSecond },
        BenchmarkMetric(name: "Total", format: "%.2f s", lowerIsBetter: true) { $0.totalSeconds },
        BenchmarkMetric(name: "Peak memory", format: "%.0f MB", lowerIsBetter: true) { $0.peakMemoryMB }
    ]
}

/// NEON | SME2 | change, with the change colored by whether SME2 is better.
private struct ComparisonTable: View {
    let neon: SME2BenchmarkResult
    let sme2: SME2BenchmarkResult

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("")
                headerText("NEON")
                headerText("SME2")
                headerText("Change")
            }

            Divider()

            ForEach(BenchmarkMetric.all) { metric in
                GridRow {
                    Text(metric.name)
                        .foregroundColor(.secondary)
                    Text(metric.formatted(neon))
                    Text(metric.formatted(sme2))
                    changeText(for: metric)
                }
            }

            GridRow {
                Text("Output tokens")
                    .foregroundColor(.secondary)
                Text("\(neon.outputTokens)")
                Text("\(sme2.outputTokens)")
                Text("")
            }

            GridRow {
                Text("Thermal")
                    .foregroundColor(.secondary)
                Text(neon.thermalState)
                Text(sme2.thermalState)
                Text("")
            }
        }
        .font(.footnote)
    }

    private func headerText(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundColor(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func changeText(for metric: BenchmarkMetric) -> Text {
        let neonValue = metric.value(neon)
        let sme2Value = metric.value(sme2)
        guard neonValue > 0 else {
            return Text("-").foregroundColor(.secondary)
        }
        let percent = (sme2Value - neonValue) / neonValue * 100
        let isBetter = metric.lowerIsBetter ? percent < 0 : percent > 0
        let color: Color = abs(percent) < 1 ? .secondary : (isBetter ? .green : .orange)
        return Text(String(format: "%+.0f%%", percent))
            .fontWeight(.semibold)
            .foregroundColor(color)
    }
}

/// Where and when a result was measured.
private struct ResultFootnote: View {
    let result: SME2BenchmarkResult

    var body: some View {
        Text("\(result.mode.displayName): \(result.deviceModel), iOS \(result.systemVersion), \(result.modelName), \(result.date.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}

#Preview {
    NavigationView {
        BenchmarkView()
    }
}
