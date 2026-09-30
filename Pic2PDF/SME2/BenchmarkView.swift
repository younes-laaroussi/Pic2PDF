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
        List {
            Section {
                LabeledContent("Running on", value: llmService.accelerationMode?.displayName ?? (llmService.isInitialized ? "Unknown" : "Not loaded"))
                LabeledContent("CPU supports SME2", value: SME2Support.isSupported ? "Yes" : "No")

                Button(action: runBenchmark) {
                    if isBusy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(runner.statusMessage.isEmpty ? "Running…" : runner.statusMessage)
                        }
                    } else {
                        Label("Run Benchmark", systemImage: "stopwatch")
                    }
                }
                .disabled(!canRun)
            } footer: {
                Text("One warm-up and \(SME2Benchmark.measuredRuns) measured runs on a bundled sample image, with greedy decoding. Takes about a minute; keep the app open. Results stay on this device.")
            }

            if let error = runner.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            resultsSection
        }
        .navigationTitle("SME2 Benchmark")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if let sme2 = runner.results[.sme2], let neon = runner.results[.neon] {
            Section {
                ForEach(BenchmarkMetric.all) { metric in
                    LabeledContent {
                        changeText(for: metric, neon: neon, sme2: sme2)
                    } label: {
                        Text(metric.name)
                        Text("NEON \(metric.formatted(neon)) · SME2 \(metric.formatted(sme2))")
                    }
                }
            } header: {
                Text("SME2 vs NEON")
            } footer: {
                Text(details(for: [neon, sme2]))
            }
        } else if let result = singleResult {
            Section {
                ForEach(BenchmarkMetric.all) { metric in
                    LabeledContent(metric.name, value: metric.formatted(result))
                }
                LabeledContent("Output tokens", value: "\(result.outputTokens)")
                LabeledContent("Thermal state", value: result.thermalState)
            } header: {
                Text("\(result.mode.displayName) Result")
            } footer: {
                Text(compareHint(missing: result.mode == .sme2 ? .neon : .sme2) + "\n\n" + details(for: [result]))
            }
        }
    }

    /// The current mode's result if there is one, otherwise whichever result exists.
    private var singleResult: SME2BenchmarkResult? {
        if let mode = llmService.accelerationMode, let result = runner.results[mode] {
            return result
        }
        return runner.results[.sme2] ?? runner.results[.neon]
    }

    /// SME2 relative to NEON, green when SME2 is better.
    private func changeText(for metric: BenchmarkMetric, neon: SME2BenchmarkResult, sme2: SME2BenchmarkResult) -> Text {
        let neonValue = metric.value(neon)
        let sme2Value = metric.value(sme2)
        guard neonValue > 0 else {
            return Text("–")
        }
        let percent = (sme2Value - neonValue) / neonValue * 100
        let isBetter = metric.lowerIsBetter ? percent < 0 : percent > 0
        let color: Color = abs(percent) < 1 ? .secondary : (isBetter ? .green : .orange)
        return Text(String(format: "%+.0f%%", percent))
            .fontWeight(.semibold)
            .foregroundColor(color)
    }

    /// Where and when each result was measured.
    private func details(for results: [SME2BenchmarkResult]) -> String {
        var lines = results.map { result in
            "\(result.mode.displayName): \(result.deviceModel), iOS \(result.systemVersion), \(result.modelName), \(result.date.formatted(date: .abbreviated, time: .shortened))"
        }
        if Set(results.map { $0.modelName }).count > 1 {
            lines.append("These results used different models. Run both modes again with the same model to compare.")
        }
        return lines.joined(separator: "\n")
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

#Preview {
    NavigationStack {
        BenchmarkView()
    }
}
