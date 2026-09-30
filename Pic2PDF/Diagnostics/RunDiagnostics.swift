//
//  RunDiagnostics.swift
//  Pic2PDF
//
//  One record per generate/refine run: timings, tokens, memory, thermal state, acceleration path,
//  and what the LaTeX auto-fixer did. Stored with SwiftData and linked to a saved result by ID
//  (kept separate from `Generation` so existing libraries migrate without schema changes there).
//

import Foundation
import SwiftData
import UIKit

@Model
final class RunDiagnostics {
    var id: UUID
    var timestamp: Date
    /// "generate" or "refine"
    var kind: String
    var generationID: UUID?

    var modelName: String
    /// "SME2", "NEON" or "Unknown" — what XNNPACK actually chose.
    var acceleration: String
    var deviceModel: String
    var osVersion: String
    var appVersion: String

    var imageCount: Int
    var imagePixels: String
    var imageMaxDimension: Int

    var preprocessSeconds: Double
    var sessionSeconds: Double
    var timeToFirstTokenSeconds: Double
    var decodeSeconds: Double
    var totalSeconds: Double

    var promptTokens: Int
    var outputTokens: Int
    var decodeTokensPerSecond: Double

    /// Peak physical footprint during the run (MB).
    var peakMemoryMB: Double
    var thermalStart: String
    var thermalEnd: String
    var lowPowerMode: Bool

    var fixSteps: [String]
    var fixRemainingError: String?
    var usedModelRepair: Bool
    var fixSeconds: Double

    var succeeded: Bool
    var errorMessage: String?

    init(kind: String) {
        id = UUID()
        timestamp = Date()
        self.kind = kind
        modelName = ""
        acceleration = "Unknown"
        deviceModel = SME2Benchmark.deviceModelIdentifier()
        osVersion = UIDevice.current.systemVersion
        appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
        imageCount = 0
        imagePixels = ""
        imageMaxDimension = 0
        preprocessSeconds = 0
        sessionSeconds = 0
        timeToFirstTokenSeconds = 0
        decodeSeconds = 0
        totalSeconds = 0
        promptTokens = 0
        outputTokens = 0
        decodeTokensPerSecond = 0
        peakMemoryMB = 0
        let thermalNow = RunDiagnostics.thermalName(ProcessInfo.processInfo.thermalState)
        thermalStart = thermalNow
        thermalEnd = thermalNow
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        fixSteps = []
        fixRemainingError = nil
        usedModelRepair = false
        fixSeconds = 0
        succeeded = false
        errorMessage = nil
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Export

extension RunDiagnostics {
    struct Export: Codable {
        let id: UUID
        let timestamp: Date
        let kind: String
        let generationID: UUID?
        let model: String
        let acceleration: String
        let device: String
        let os: String
        let app: String
        let images: Int
        let imagePixels: String
        let imageMaxDimension: Int
        let preprocessSeconds: Double
        let sessionSeconds: Double
        let timeToFirstTokenSeconds: Double
        let decodeSeconds: Double
        let totalSeconds: Double
        let promptTokens: Int
        let outputTokens: Int
        let decodeTokensPerSecond: Double
        let peakMemoryMB: Double
        let thermalStart: String
        let thermalEnd: String
        let lowPowerMode: Bool
        let fixSteps: [String]
        let fixRemainingError: String?
        let usedModelRepair: Bool
        let fixSeconds: Double
        let succeeded: Bool
        let errorMessage: String?
    }

    var export: Export {
        Export(id: id, timestamp: timestamp, kind: kind, generationID: generationID, model: modelName,
               acceleration: acceleration, device: deviceModel, os: osVersion, app: appVersion,
               images: imageCount, imagePixels: imagePixels, imageMaxDimension: imageMaxDimension,
               preprocessSeconds: preprocessSeconds, sessionSeconds: sessionSeconds,
               timeToFirstTokenSeconds: timeToFirstTokenSeconds, decodeSeconds: decodeSeconds,
               totalSeconds: totalSeconds, promptTokens: promptTokens, outputTokens: outputTokens,
               decodeTokensPerSecond: decodeTokensPerSecond, peakMemoryMB: peakMemoryMB,
               thermalStart: thermalStart, thermalEnd: thermalEnd, lowPowerMode: lowPowerMode,
               fixSteps: fixSteps, fixRemainingError: fixRemainingError, usedModelRepair: usedModelRepair,
               fixSeconds: fixSeconds, succeeded: succeeded, errorMessage: errorMessage)
    }

    static func jsonData(_ runs: [RunDiagnostics]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(runs.map(\.export))) ?? Data("[]".utf8)
    }

    static func csvData(_ runs: [RunDiagnostics]) -> Data {
        let header = "timestamp,kind,model,acceleration,device,os,app,images,image_max_dim,preprocess_s,session_s,ttft_s,decode_s,total_s,prompt_tokens,output_tokens,decode_tok_s,peak_memory_mb,thermal_start,thermal_end,low_power,fix_steps,model_repair,fix_s,remaining_error,succeeded,error"
        let iso = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = runs.map { r in
            [iso.string(from: r.timestamp), r.kind, q(r.modelName), r.acceleration, r.deviceModel, r.osVersion, q(r.appVersion),
             "\(r.imageCount)", "\(r.imageMaxDimension)",
             String(format: "%.3f", r.preprocessSeconds), String(format: "%.3f", r.sessionSeconds),
             String(format: "%.3f", r.timeToFirstTokenSeconds), String(format: "%.3f", r.decodeSeconds),
             String(format: "%.3f", r.totalSeconds), "\(r.promptTokens)", "\(r.outputTokens)",
             String(format: "%.2f", r.decodeTokensPerSecond), String(format: "%.0f", r.peakMemoryMB),
             r.thermalStart, r.thermalEnd, r.lowPowerMode ? "1" : "0", q(r.fixSteps.joined(separator: "; ")),
             r.usedModelRepair ? "1" : "0", String(format: "%.3f", r.fixSeconds), q(r.fixRemainingError ?? ""),
             r.succeeded ? "1" : "0", q(r.errorMessage ?? "")].joined(separator: ",")
        }
        return Data(([header] + rows).joined(separator: "\n").utf8)
    }
}
