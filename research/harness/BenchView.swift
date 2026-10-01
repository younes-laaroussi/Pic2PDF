//
//  BenchView.swift — minimal host view for the headless benchmark mode.
//  Deliberately does NOT touch OnDeviceLLMService (which auto-loads a model
//  on first access) so the harness controls the only LlmInference instance.
//
import SwiftUI

struct BenchView: View {
    @State private var started = false
    var body: some View {
        VStack(spacing: 12) {
            Text("Benchmark mode").font(.headline)
            Text("PIC2PDF_BENCH=1 — see console").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            guard !started else { return }
            started = true
            UIApplication.shared.isIdleTimerDisabled = true
            Task.detached(priority: .userInitiated) { await Bench.main() }
        }
    }
}
