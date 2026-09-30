//
//  RunDiagnosticsView.swift
//  Pic2PDF
//
//  Rows describing one run. Used in the run detail screen and in History.
//

import SwiftUI

struct RunDiagnosticsSections: View {
    let run: RunDiagnostics

    var body: some View {
        Section("Timing") {
            LabeledContent("Time to first token", value: seconds(run.timeToFirstTokenSeconds))
            LabeledContent("Decode speed", value: String(format: "%.1f tok/s", run.decodeTokensPerSecond))
            LabeledContent("Decode time", value: seconds(run.decodeSeconds))
            LabeledContent("Total", value: seconds(run.totalSeconds))
            if run.kind == "generate" {
                LabeledContent("Image preprocessing", value: seconds(run.preprocessSeconds))
            }
            LabeledContent("Session setup", value: seconds(run.sessionSeconds))
        }

        Section("Tokens & Memory") {
            LabeledContent("Prompt tokens", value: "\(run.promptTokens)")
            LabeledContent("Output tokens", value: "\(run.outputTokens)")
            LabeledContent("Peak memory", value: String(format: "%.0f MB", run.peakMemoryMB))
            LabeledContent("Thermal state", value: run.thermalStart == run.thermalEnd ? run.thermalStart : "\(run.thermalStart) → \(run.thermalEnd)")
            if run.lowPowerMode { LabeledContent("Low Power Mode", value: "On") }
        }

        if run.kind == "generate" {
            Section("Input") {
                LabeledContent("Images", value: "\(run.imageCount)")
                if !run.imagePixels.isEmpty { LabeledContent("Sent to model", value: run.imagePixels) }
            }
        }

        Section {
            if run.fixSteps.isEmpty && run.fixRemainingError == nil {
                Label("No fixes needed", systemImage: "checkmark.circle")
            }
            ForEach(Array(run.fixSteps.enumerated()), id: \.offset) { _, step in
                Label(step, systemImage: "wrench.adjustable")
            }
            if let error = run.fixRemainingError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if run.fixSeconds > 0 {
                LabeledContent("Checking time", value: seconds(run.fixSeconds))
            }
        } header: {
            Text("LaTeX Check")
        } footer: {
            Text(run.usedModelRepair ? "The model fixed an error that latex.js reported." : "Checked with latex.js, the same library that renders the preview.")
        }

        Section("System") {
            LabeledContent("Acceleration", value: run.acceleration)
            LabeledContent("Model", value: run.modelName)
            LabeledContent("Device", value: run.deviceModel)
            LabeledContent("iOS", value: run.osVersion)
            LabeledContent("App", value: run.appVersion)
        }

        if !run.succeeded, let error = run.errorMessage {
            Section("Error") {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    private func seconds(_ value: Double) -> String {
        String(format: value < 10 ? "%.2f s" : "%.1f s", value)
    }
}

struct RunDiagnosticsDetailView: View {
    let run: RunDiagnostics

    var body: some View {
        List {
            RunDiagnosticsSections(run: run)
        }
        .navigationTitle(run.kind == "refine" ? "Refinement" : "Generation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: DiagnosticsExport.file(for: [run], format: .json),
                      preview: SharePreview("Run diagnostics"))
        }
    }
}

/// Writes diagnostics to a temporary file for ShareLink.
enum DiagnosticsExport {
    enum Format { case json, csv }

    static func file(for runs: [RunDiagnostics], format: Format) -> URL {
        let name = "img2latex-diagnostics-\(Int(Date().timeIntervalSince1970)).\(format == .json ? "json" : "csv")"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let data = format == .json ? RunDiagnostics.jsonData(runs) : RunDiagnostics.csvData(runs)
        try? data.write(to: url, options: .atomic)
        return url
    }
}
