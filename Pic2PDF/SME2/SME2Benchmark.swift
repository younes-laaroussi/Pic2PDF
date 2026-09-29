//
//  SME2Benchmark.swift
//  Pic2PDF
//
//  In-app SME2 vs NEON benchmark: fixed photo, prompt and settings, so runs are
//  comparable across launches. Results are stored on the device only.
//

import Foundation
import UIKit
import Combine

/// Metrics for one benchmark generation (same definitions as the research harness).
struct SME2BenchmarkRun {
    /// Generate call -> first non-empty chunk.
    let timeToFirstTokenSeconds: Double
    /// (output tokens - 1) / (last chunk - first chunk), tokens counted with the model's tokenizer.
    let decodeTokensPerSecond: Double
    /// Image added -> last chunk.
    let totalSeconds: Double
    let outputTokens: Int
    let peakMemoryMB: Double
    let thermalState: ProcessInfo.ThermalState
}

/// Median of the measured runs for one mode. Stored as JSON in UserDefaults under `benchmark_<mode>`.
struct SME2BenchmarkResult: Codable {
    let mode: SME2Support.Mode
    let date: Date
    let deviceModel: String
    let systemVersion: String
    let modelName: String
    let measuredRuns: Int
    let timeToFirstTokenSeconds: Double
    let decodeTokensPerSecond: Double
    let totalSeconds: Double
    let outputTokens: Int
    let peakMemoryMB: Double
    /// Worst thermal state seen across the measured runs.
    let thermalState: String
}

enum SME2Benchmark {
    /// Measured runs after one warm-up run.
    static let measuredRuns = 3
    /// Same cap as the generation path (the vision encoder's largest native size).
    static let imageMaxDimension = 768
    /// Bundled sample in Pic2PDF/SME2/. Any extension below works, so a real photo can replace it.
    static let sampleImageName = "sme2_benchmark_sample"

    static func sampleImage() -> CGImage? {
        for fileExtension in ["jpg", "jpeg", "png", "heic"] {
            if let path = Bundle.main.path(forResource: sampleImageName, ofType: fileExtension),
               let image = UIImage(contentsOfFile: path) {
                return image.cgImage
            }
        }
        return nil
    }

    // MARK: - Results

    static func makeResult(mode: SME2Support.Mode, modelName: String, runs: [SME2BenchmarkRun]) -> SME2BenchmarkResult {
        let worstThermalState = runs.map { $0.thermalState.rawValue }.max() ?? ProcessInfo.ThermalState.nominal.rawValue
        return SME2BenchmarkResult(
            mode: mode,
            date: Date(),
            deviceModel: deviceModelIdentifier(),
            systemVersion: UIDevice.current.systemVersion,
            modelName: modelName,
            measuredRuns: runs.count,
            timeToFirstTokenSeconds: median(runs.map { $0.timeToFirstTokenSeconds }),
            decodeTokensPerSecond: median(runs.map { $0.decodeTokensPerSecond }),
            totalSeconds: median(runs.map { $0.totalSeconds }),
            outputTokens: Int(median(runs.map { Double($0.outputTokens) }).rounded()),
            peakMemoryMB: median(runs.map { $0.peakMemoryMB }),
            thermalState: ProcessMetrics.thermalStateDescription(ProcessInfo.ThermalState(rawValue: worstThermalState) ?? .nominal)
        )
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Hardware model identifier, e.g. "iPhone17,2" (UIDevice.model only says "iPhone").
    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    // MARK: - Storage

    static func storageKey(for mode: SME2Support.Mode) -> String {
        return "benchmark_\(mode.rawValue)"
    }

    static func loadResult(for mode: SME2Support.Mode) -> SME2BenchmarkResult? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: mode)) else { return nil }
        return try? JSONDecoder().decode(SME2BenchmarkResult.self, from: data)
    }

    static func save(_ result: SME2BenchmarkResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(for: result.mode))
    }
}

/// Samples resident memory on a timer, so the peak during prefill (when no chunks arrive) is caught.
final class PeakMemorySampler {
    private(set) var peakMB: Double = 0
    private var task: Task<Void, Never>?

    func start() {
        sample()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                self.sample()
            }
        }
    }

    func sample() {
        peakMB = max(peakMB, ProcessMetrics.currentResidentMemoryMB())
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Drives the benchmark for BenchmarkView and holds the stored results.
/// Shared so a run keeps its state if the user leaves the screen and comes back.
final class SME2BenchmarkRunner: ObservableObject {
    static let shared = SME2BenchmarkRunner()

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var results: [SME2Support.Mode: SME2BenchmarkResult] = [:]

    private init() {
        for mode in [SME2Support.Mode.sme2, .neon] {
            results[mode] = SME2Benchmark.loadResult(for: mode)
        }
    }

    func run(on service: OnDeviceLLMService) async {
        guard !isRunning else { return }
        guard let image = SME2Benchmark.sampleImage() else {
            errorMessage = "The benchmark image is missing from the app bundle."
            return
        }
        // Label the result with what XNNPACK actually chose, not just what was requested.
        let mode = SME2Support.activeMode ?? SME2Support.requestedModeAtLaunch

        isRunning = true
        errorMessage = nil
        defer {
            isRunning = false
            statusMessage = ""
        }

        do {
            let runs = try await service.runSME2Benchmark(image: image, measuredRuns: SME2Benchmark.measuredRuns) { message in
                statusMessage = message
            }
            let result = SME2Benchmark.makeResult(mode: mode, modelName: service.selectedModel.displayName, runs: runs)
            SME2Benchmark.save(result)
            results[mode] = result
            NSLog("[SME2Benchmark] \(mode.displayName): ttft=\(result.timeToFirstTokenSeconds)s decode=\(result.decodeTokensPerSecond) tok/s total=\(result.totalSeconds)s peak=\(result.peakMemoryMB) MB")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
