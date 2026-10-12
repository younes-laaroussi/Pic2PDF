//
//  ModelDownloadManager.swift
//  Pic2PDF
//
//  Created for Arm AI Developer Challenge 2025
//

import Foundation
import Combine
import CryptoKit

/// Configuration for downloadable models
struct DownloadableModelConfig {
    let identifier: ModelIdentifier
    /// Tried in order. If one can't be reached (offline, blocked by a network filter, server error)
    /// or sends the wrong file, the next one is used.
    let downloadURLs: [URL]
    let sizeBytes: Int64
    /// SHA-256 of the .task file, checked before the download is kept.
    let sha256: String

    /// Cloudflare R2 bucket with the .task files.
    static let r2BaseURL = "https://pub-69c747d5957f4104a2f87b0aca35a2af.r2.dev"

    // Unmodified copies of the int4 .task files from google/gemma-3n-E2B-it-litert-preview
    // and google/gemma-3n-E4B-it-litert-preview on Hugging Face (gated there, so mirrored).
    static let availableModels: [ModelIdentifier: DownloadableModelConfig] = [
        .gemma2B: DownloadableModelConfig(
            identifier: .gemma2B,
            downloadURLs: mirrors(for: .gemma2B),
            sizeBytes: 3_136_226_711, // ~3.1 GB
            sha256: "a7f544cfee68f579fabadb22aa9284faa4020a0f5358d0e15b49fdd4cefe4200"
        ),
        .gemma4B: DownloadableModelConfig(
            identifier: .gemma4B,
            downloadURLs: mirrors(for: .gemma4B),
            sizeBytes: 4_405_655_031, // ~4.4 GB
            sha256: "2b8e9d04bf8c5c50346d248c5e24a7e65102251c94dee6f04d5dce5ce3e6ac4f"
        )
    ]

    private static func mirrors(for model: ModelIdentifier) -> [URL] {
        return [
            URL(string: "\(r2BaseURL)/\(model.fileName)")!
        ]
    }
}

/// Model download status
enum ModelDownloadStatus: Equatable {
    case notStarted
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64)
    case verifying
    case extracting
    case completed
    case failed(error: String)
    case cancelled

    var isInProgress: Bool {
        switch self {
        case .downloading, .verifying, .extracting:
            return true
        default:
            return false
        }
    }

    var isCompleted: Bool {
        if case .completed = self {
            return true
        }
        return false
    }
}

/// Manages downloading and storing ML models at runtime
@MainActor
final class ModelDownloadManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var downloadStatus: ModelDownloadStatus = .notStarted
    @Published var downloadSpeed: Double = 0.0 // MB/s
    @Published var estimatedTimeRemaining: TimeInterval = 0

    // MARK: - Private Properties
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var downloadTask: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var isCancelled = false
    private var expectedBytes: Int64 = 0
    private var downloadStartTime: Date?
    private var lastProgressUpdate: Date?
    private var lastBytesDownloaded: Int64 = 0

    // MARK: - Singleton
    static let shared = ModelDownloadManager()

    // MARK: - Model Storage
    private var modelsDirectory: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelsDir = documentsDir.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir
    }

    /// Get the local path for a model file
    func localModelPath(for identifier: ModelIdentifier) -> URL {
        return modelsDirectory.appendingPathComponent(identifier.fileName)
    }

    /// Where a download is kept until its checksum has been verified.
    private func partialPath(for identifier: ModelIdentifier) -> URL {
        return modelsDirectory.appendingPathComponent(identifier.fileName + ".download")
    }

    /// Check if a model is already downloaded
    func isModelDownloaded(_ identifier: ModelIdentifier) -> Bool {
        let path = localModelPath(for: identifier)
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Get the size of a downloaded model in MB
    func modelSize(_ identifier: ModelIdentifier) -> Double? {
        let path = localModelPath(for: identifier)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let fileSize = attributes[.size] as? Int64 else {
            return nil
        }
        return Double(fileSize) / (1024 * 1024)
    }

    // MARK: - Download Methods

    /// Downloads a model, trying each mirror in turn, and keeps it only if its size and SHA-256 match.
    func downloadModel(_ identifier: ModelIdentifier) async throws {
        guard let config = DownloadableModelConfig.availableModels[identifier] else {
            throw ModelDownloadError.configurationNotFound
        }

        // Check if already downloaded
        if isModelDownloaded(identifier) {
            downloadStatus = .completed
            return
        }

        guard !downloadStatus.isInProgress else {
            throw ModelDownloadError.alreadyDownloading
        }

        // Check available disk space
        if !hasEnoughDiskSpace(requiredBytes: config.sizeBytes) {
            throw ModelDownloadError.insufficientDiskSpace(requiredMB: Double(config.sizeBytes) / (1024 * 1024))
        }

        isCancelled = false
        var failures: [Error] = []
        for url in config.downloadURLs {
            do {
                try await download(from: url, to: partialPath(for: identifier), expectedBytes: config.sizeBytes)
                downloadStatus = .verifying
                try await Self.verify(partialPath(for: identifier), sizeBytes: config.sizeBytes, sha256: config.sha256)
                if isCancelled { throw CancellationError() }
                try? FileManager.default.removeItem(at: localModelPath(for: identifier))
                try FileManager.default.moveItem(at: partialPath(for: identifier), to: localModelPath(for: identifier))
                downloadStatus = .completed
                NSLog("[ModelDownload] \(identifier.displayName) downloaded from \(url.host ?? url.absoluteString) and verified")
                return
            } catch {
                try? FileManager.default.removeItem(at: partialPath(for: identifier))
                if isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    downloadStatus = .cancelled
                    throw CancellationError()
                }
                NSLog("[ModelDownload] \(url.host ?? url.absoluteString) failed: \(error)")
                failures.append(error)
            }
        }

        let error = ModelDownloadError.allMirrorsFailed(ModelDownloadError.reason(for: failures))
        downloadStatus = .failed(error: error.localizedDescription)
        throw error
    }

    /// Cancel ongoing download
    func cancelDownload() {
        isCancelled = true
        downloadTask?.cancel()
        downloadTask = nil
        downloadStatus = .cancelled
    }

    /// Delete a downloaded model
    func deleteModel(_ identifier: ModelIdentifier) throws {
        let path = localModelPath(for: identifier)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    // MARK: - Private Helper Methods

    /// Downloads one URL to `destination`. Throws on network errors and non-2xx responses.
    private func download(from url: URL, to destination: URL, expectedBytes: Int64) async throws {
        try? FileManager.default.removeItem(at: destination)
        self.expectedBytes = expectedBytes
        downloadStatus = .downloading(progress: 0, bytesDownloaded: 0, totalBytes: expectedBytes)
        downloadStartTime = Date()
        lastProgressUpdate = Date()
        lastBytesDownloaded = 0
        downloadSpeed = 0
        NSLog("[ModelDownload] Downloading \(url.absoluteString)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = session.downloadTask(with: url)
            // The delegate moves the finished file here; it runs off the main actor, so pass the path on the task.
            task.taskDescription = destination.path
            downloadTask = task
            downloadContinuation = continuation
            task.resume()
        }
        downloadTask = nil
    }

    private func finishDownloadTask(_ result: Result<Void, Error>) {
        downloadContinuation?.resume(with: result)
        downloadContinuation = nil
    }

    /// Checks the file's size and SHA-256 off the main thread (a few seconds for 3 GB).
    private nonisolated static func verify(_ url: URL, sizeBytes: Int64, sha256: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard size == sizeBytes else {
                throw ModelDownloadError.wrongFile("size \(size), expected \(sizeBytes)")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 16 * 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == sha256 else {
                throw ModelDownloadError.wrongFile("SHA-256 \(digest), expected \(sha256)")
            }
        }.value
    }

    private func hasEnoughDiskSpace(requiredBytes: Int64) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let freeSpace = attributes[.systemFreeSize] as? Int64 else {
            return false
        }
        // Keep 500MB buffer
        return freeSpace > (requiredBytes + 500 * 1024 * 1024)
    }

    private func calculateDownloadSpeed(bytesDownloaded: Int64) {
        guard let lastUpdate = lastProgressUpdate else { return }

        let now = Date()
        let timeDiff = now.timeIntervalSince(lastUpdate)

        if timeDiff >= 1.0 { // Update speed every second
            let bytesDiff = bytesDownloaded - lastBytesDownloaded
            downloadSpeed = Double(bytesDiff) / (1024 * 1024) / timeDiff // MB/s

            lastProgressUpdate = now
            lastBytesDownloaded = bytesDownloaded
        }
    }

    private func calculateEstimatedTime(bytesDownloaded: Int64, totalBytes: Int64) {
        if downloadSpeed > 0 {
            let remainingBytes = totalBytes - bytesDownloaded
            let remainingMB = Double(remainingBytes) / (1024 * 1024)
            estimatedTimeRemaining = remainingMB / downloadSpeed
        }
    }
}

// MARK: - URLSessionDownloadDelegate
extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it now.
        let result: Result<Void, Error>
        if let response = downloadTask.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            // Error pages also arrive here as finished downloads.
            result = .failure(ModelDownloadError.httpStatus(response.statusCode))
        } else if let path = downloadTask.taskDescription {
            let destination = URL(fileURLWithPath: path)
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                result = .success(())
            } catch {
                result = .failure(error)
            }
        } else {
            result = .failure(ModelDownloadError.unknownModel)
        }

        Task { @MainActor in
            self.finishDownloadTask(result)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard self.downloadTask === downloadTask else { return }
            let totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
            let progress = Double(totalBytesWritten) / Double(max(totalBytes, 1))
            downloadStatus = .downloading(progress: progress, bytesDownloaded: totalBytesWritten, totalBytes: totalBytes)

            calculateDownloadSpeed(bytesDownloaded: totalBytesWritten)
            calculateEstimatedTime(bytesDownloaded: totalBytesWritten, totalBytes: totalBytes)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is reported by didFinishDownloadingTo, which runs first.
        guard let error = error else { return }
        Task { @MainActor in
            self.finishDownloadTask(.failure(error))
        }
    }
}

// MARK: - Error Types
nonisolated enum ModelDownloadError: LocalizedError {
    /// Why every mirror failed, as shown to the user.
    enum Reason {
        case offline
        case unreachable
        case damaged
    }

    case configurationNotFound
    case insufficientDiskSpace(requiredMB: Double)
    case alreadyDownloading
    case unknownModel
    case httpStatus(Int)
    case wrongFile(String)
    case allMirrorsFailed(Reason)

    var errorDescription: String? {
        switch self {
        case .configurationNotFound:
            return "Model configuration not found"
        case .insufficientDiskSpace(let requiredMB):
            return "Insufficient disk space. Need at least \(Int(requiredMB))MB free"
        case .alreadyDownloading:
            return "A model is already downloading."
        case .unknownModel:
            return "Unknown model identifier"
        case .httpStatus(let code):
            return "The server answered with HTTP \(code)."
        case .wrongFile(let detail):
            return "The downloaded file doesn't match the model (\(detail))."
        case .allMirrorsFailed(.offline):
            return "You're offline. Connect to the internet and try again."
        case .allMirrorsFailed(.unreachable):
            return "Couldn't reach the download servers. Work networks and VPNs sometimes block them; try another network."
        case .allMirrorsFailed(.damaged):
            return "The download was incomplete or damaged. Try again."
        }
    }

    static func reason(for failures: [Error]) -> Reason {
        let urlErrors = failures.compactMap { $0 as? URLError }
        if !urlErrors.isEmpty && urlErrors.count == failures.count && urlErrors.allSatisfy({ $0.code == .notConnectedToInternet }) {
            return .offline
        }
        if failures.allSatisfy({ if case ModelDownloadError.wrongFile = $0 { return true } else { return false } }) {
            return .damaged
        }
        return .unreachable
    }
}
