//
//  OnDeviceLLMService.swift
//  Pic2PDF
//
//  Created by AI Assistant on 2025-01-30.
//

import Foundation
import UIKit
import MediaPipeTasksGenAI
import ZIPFoundation
import Combine
import Accelerate
import os.signpost

/// Represents the available AI models optimized for image-to-LaTeX conversion
public enum ModelIdentifier: String, CaseIterable, Identifiable {
    case gemma2B = "gemma-3n-E2B-it-int4"
    case gemma4B = "gemma-3n-E4B-it-int4"

    public var id: String { self.rawValue }
    public var fileName: String { "\(self.rawValue).task" }

    public var displayName: String {
        switch self {
        case .gemma2B: return "Vision Model 2B"
        case .gemma4B: return "Vision Model 4B"
        }
    }

    /// Checks which models are actually present in the app bundle
    public static func availableInBundle() -> [ModelIdentifier] {
        return ModelIdentifier.allCases.filter { modelId in
            Bundle.main.path(forResource: modelId.rawValue, ofType: "task") != nil
        }
    }
}

/// Manages the on-device AI model, including initialization and vision component extraction
struct OnDeviceModel {
    private(set) var inference: LlmInference
    let identifier: ModelIdentifier

    init(modelIdentifier: ModelIdentifier, maxTokens: Int = 1000) throws {
        // Normally already done in Pic2PDFApp.init(); must happen before LlmInference is created.
        SME2Support.configureBeforeModelLoad()

        self.identifier = modelIdentifier
        let fileManager = FileManager.default
        let cacheDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)

        // First check for downloaded model in documents directory
        let downloadManager = ModelDownloadManager.shared
        let downloadedModelPath = downloadManager.localModelPath(for: modelIdentifier)
        
        var sourceModelPath: String?
        
        if fileManager.fileExists(atPath: downloadedModelPath.path) {
            // Use downloaded model
            sourceModelPath = downloadedModelPath.path
            NSLog("Using downloaded model at: \(downloadedModelPath.path)")
        } else if let bundleModelPath = Bundle.main.path(forResource: modelIdentifier.rawValue, ofType: "task") {
            // Fallback to bundled model if available
            sourceModelPath = bundleModelPath
            NSLog("Using bundled model at: \(bundleModelPath)")
        }
        
        guard let modelPath = sourceModelPath else {
            let errorMessage = "Model file '\(modelIdentifier.fileName)' not found. Please download the model first."
            NSLog(errorMessage)
            throw NSError(domain: "ModelSetupError", code: 1001, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        let modelCopyPath = cacheDir.appendingPathComponent(modelIdentifier.fileName)

        // Copy to cache if not already there or if source has been updated
        if !fileManager.fileExists(atPath: modelCopyPath.path) {
            try fileManager.copyItem(atPath: modelPath, toPath: modelCopyPath.path)
        }

        // Define vision component filenames within the .task archive
        let visionEncoderFileName = "TF_LITE_VISION_ENCODER"
        let visionAdapterFileName = "TF_LITE_VISION_ADAPTER"

        let extractedVisionEncoderPath = cacheDir.appendingPathComponent(visionEncoderFileName)
        let extractedVisionAdapterPath = cacheDir.appendingPathComponent(visionAdapterFileName)

        // Extract vision models if they don't exist
        if !fileManager.fileExists(atPath: extractedVisionEncoderPath.path) ||
           !fileManager.fileExists(atPath: extractedVisionAdapterPath.path) {
            NSLog("Extracting vision models from .task file...")
            do {
                try OnDeviceModel.extractVisionModels(
                    fromArchive: modelCopyPath,
                    toDirectory: cacheDir,
                    filesToExtract: [visionEncoderFileName, visionAdapterFileName]
                )
                NSLog("Successfully extracted vision models.")
            } catch {
                let extractionErrorMessage = "Error extracting vision components: \(error.localizedDescription)"
                NSLog(extractionErrorMessage)
                // Continue without vision components for now
            }
        } else {
            NSLog("Vision models already exist in cache.")
        }

        let options = LlmInference.Options(modelPath: modelCopyPath.path)
        options.maxTokens = maxTokens

        // Configure for vision modality
        options.visionEncoderPath = extractedVisionEncoderPath.path
        options.visionAdapterPath = extractedVisionAdapterPath.path
        options.maxImages = 5 // Support up to 5 images for document conversion

        // XNNPACK writes packed weights to <modelPath>.xnnpack_cache, but the cache is not keyed by ISA:
        // loading a NEON-built cache with SME2 on aborts the process. Rebuild it when the mode changes.
        let launchMode = SME2Support.requestedModeAtLaunch
        let weightCacheURL = URL(fileURLWithPath: modelCopyPath.path + ".xnnpack_cache")
        let weightCacheModeKey = "xnnCacheBuiltMode_\(modelIdentifier.fileName)"
        try OnDeviceModel.invalidateWeightCacheIfNeeded(at: weightCacheURL, builtModeKey: weightCacheModeKey, launchMode: launchMode)

        // XNNPACK aborts the process (it can't be caught) if a cache on disk doesn't match the graph it is
        // loading, which would crash every launch. Mark the load as in progress with a file (written
        // synchronously, unlike UserDefaults); if the next launch still finds it, the previous load died,
        // so start from an empty cache.
        let loadMarkerURL = URL(fileURLWithPath: weightCacheURL.path + ".loading")
        if fileManager.fileExists(atPath: loadMarkerURL.path) {
            if fileManager.fileExists(atPath: weightCacheURL.path) {
                try? fileManager.removeItem(at: weightCacheURL)
                NSLog("[SME2] Previous model load did not finish; deleted XNNPACK weight cache \(weightCacheURL.lastPathComponent)")
            }
            UserDefaults.standard.removeObject(forKey: weightCacheModeKey)
        }
        fileManager.createFile(atPath: loadMarkerURL.path, contents: nil)

        inference = try LlmInference(options: options)
        try? fileManager.removeItem(at: loadMarkerURL)
        UserDefaults.standard.set(launchMode.rawValue, forKey: weightCacheModeKey)
        SME2Support.recordActiveModeAfterLoad()
    }

    /// Deletes XNNPACK's weight cache if it was built in a different SME2 mode, or by an older
    /// app version (no marker; those only ran NEON). Costs a one-time rebuild (~8 s) on this load.
    private static func invalidateWeightCacheIfNeeded(at cacheURL: URL, builtModeKey: String, launchMode: SME2Support.Mode) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheURL.path) else { return }

        let builtMode = UserDefaults.standard.string(forKey: builtModeKey)
        guard builtMode != launchMode.rawValue else { return }

        let sizeMB = Double((try? cacheURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / (1024 * 1024)
        do {
            try fileManager.removeItem(at: cacheURL)
            NSLog("[SME2] Deleted XNNPACK weight cache \(cacheURL.lastPathComponent) (\(String(format: "%.0f", sizeMB)) MB), built for \(builtMode ?? "unknown/older app"), now \(launchMode.rawValue)")
        } catch {
            NSLog("[SME2] Failed to delete XNNPACK weight cache \(cacheURL.lastPathComponent): \(error)")
            // A cache from the other ISA would abort the process on load; fail with an error instead.
            if (builtMode ?? SME2Support.Mode.neon.rawValue) != launchMode.rawValue {
                let errorMessage = "Could not reset the model cache for the new acceleration mode. Please restart the app."
                throw NSError(domain: "ModelSetupError", code: 1002, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
    }

    private static func extractVisionModels(fromArchive archiveURL: URL, toDirectory destinationURL: URL, filesToExtract: [String]) throws {
        let fileManager = FileManager.default
        let archive = try Archive(url: archiveURL, accessMode: .read)

        for fileName in filesToExtract {
            guard let entry = archive[fileName] else {
                NSLog("Vision component '\(fileName)' not found in archive")
                continue
            }

            let destinationFilePath = destinationURL.appendingPathComponent(fileName)

            if fileManager.fileExists(atPath: destinationFilePath.path) {
                try fileManager.removeItem(at: destinationFilePath)
            }

            NSLog("Extracting '\(fileName)' to cache")
            _ = try archive.extract(entry, to: destinationFilePath)
        }
    }
}

/// Represents a chat session with the on-device AI model
final class AIChatSession {
    private let model: OnDeviceModel
    private var session: LlmInference.Session

    init(model: OnDeviceModel,
         topK: Int = 40,
         topP: Float = 0.9,
         temperature: Float = 0.7,
         randomSeed: Int? = nil,
         enableVisionModality: Bool = true) throws {
        self.model = model

        let options = LlmInference.Session.Options()
        options.topk = topK
        options.topp = topP
        options.temperature = temperature
        if let randomSeed = randomSeed {
            options.randomSeed = randomSeed
        }
        options.enableVisionModality = enableVisionModality
        
        NSLog("[AIChatSession] Creating session with visionModality=\(enableVisionModality), topK=\(topK), temp=\(temperature)")
        session = try LlmInference.Session(llmInference: model.inference, options: options)
        NSLog("[AIChatSession] Session created successfully")
    }

    /// Adds an image to the current query context
    func addImageToQuery(image: CGImage) throws {
        try session.addImage(image: image)
    }

    /// Generates LaTeX from images and text prompt
    func generateLaTeX(prompt: String) async throws -> AsyncThrowingStream<String, any Error> {
        try session.addQueryChunk(inputText: prompt)
        let resultStream = session.generateResponseAsync()
        return resultStream
    }

    /// Gets the generation time for the last response
    func getLastResponseGenerationTime() -> TimeInterval? {
        return session.metrics.responseGenerationTimeInSeconds
    }

    /// Estimates token count for text
    func sizeInTokens(text: String) throws -> Int {
        return try session.sizeInTokens(text: text)
    }
}

/// Performance metrics for a single generation
struct GenerationMetrics: Identifiable {
    let id = UUID()
    let timestamp: Date
    let modelIdentifier: ModelIdentifier
    let inputImageCount: Int
    let outputTokenCount: Int
    let generationTime: TimeInterval
    let tokensPerSecond: Double
    let memoryUsageMB: Double
    let batteryLevelBefore: Int
    let batteryLevelAfter: Int
    let thermalState: ProcessInfo.ThermalState
}

/// Main service class for on-device LLM processing in Pic2PDF
@MainActor
final class OnDeviceLLMService: ObservableObject {
    // MARK: - Published Properties
    @Published var isInitialized = false
    @Published var initializationError: String?
    @Published var modelInitializationTime: Double = 0.0
    /// SME2 or NEON, as chosen by XNNPACK at model load. nil until the model has loaded.
    @Published var accelerationMode: SME2Support.Mode?

    // MARK: - Performance Tracking
    @Published var generationHistory: [GenerationMetrics] = []
    @Published var totalGenerations: Int = 0
    @Published var averageGenerationTime: Double = 0.0
    @Published var averageTokensPerSecond: Double = 0.0
    @Published var peakMemoryUsage: Double = 0.0
    @Published var totalTokensGenerated: Int = 0

    // MARK: - Real-time Metrics
    @Published var currentMemoryUsage: Double = 0.0
    @Published var batteryLevel: Int = 100
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var currentTokensPerSecond: Double = 0.0
    
    // MARK: - Live Generation Streaming
    @Published var streamingLaTeX: String = ""

    // MARK: - Busy State
    /// True while generateLaTeX or refineLaTeX is running.
    @Published private(set) var isGenerating = false
    /// True while the SME2 benchmark is running. Generation is refused meanwhile (one model, one session at a time).
    @Published private(set) var isBenchmarking = false

    // MARK: - Public Model Access
    /// Public access to current model information for UI display
    var currentModelInfo: (identifier: ModelIdentifier, isInitialized: Bool) {
        if let model = currentModel {
            return (model.identifier, true)
        }
        return (preferredModel, false) // Return preferred model even if not initialized
    }
    
    /// Get the currently selected model identifier
    var selectedModel: ModelIdentifier {
        return preferredModel
    }

    // MARK: - Private Properties
    private var currentModel: OnDeviceModel?
    private var currentSession: AIChatSession?
    private var preferredModel: ModelIdentifier = .gemma2B
    private var metricsTimer: Timer?
    private let signpostLog = OSLog(subsystem: "com.pic2pdf.app", category: "LLM")
    private var firstTokenLogged = false

    private var isPerformanceModeEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "performanceModeEnabled")
    }
    
    // User-configurable LLM parameters
    private var userTemperature: Float {
        let value = UserDefaults.standard.double(forKey: "llmTemperature")
        return Float(value > 0 ? value : 0.7)
    }
    
    private var userTopP: Float {
        let value = UserDefaults.standard.double(forKey: "llmTopP")
        return Float(value > 0 ? value : 0.9)
    }
    
    private var userTopK: Int {
        let value = UserDefaults.standard.integer(forKey: "llmTopK")
        return value > 0 ? value : 40
    }
    
    private var userMaxTokens: Int {
        let value = UserDefaults.standard.integer(forKey: "llmMaxTokens")
        return value > 0 ? value : 2000
    }

    // MARK: - Singleton
    static let shared = OnDeviceLLMService()

    private init() {
        setupMetricsMonitoring()
        Task {
            await initializeModel()
        }
    }

    // MARK: - Metrics Monitoring
    private func setupMetricsMonitoring() {
        // Update real-time metrics every second
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateRealTimeMetrics()
            }
        }

        // Battery monitoring
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = Int((UIDevice.current.batteryLevel * 100).rounded())

        NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.batteryLevel = Int((UIDevice.current.batteryLevel * 100).rounded())
        }

        // Thermal state monitoring
        thermalState = ProcessInfo.processInfo.thermalState
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    private func updateRealTimeMetrics() {
        currentMemoryUsage = ProcessMetrics.currentResidentMemoryMB()

        // Update peak memory usage
        if currentMemoryUsage > peakMemoryUsage {
            peakMemoryUsage = currentMemoryUsage
        }
    }

    private func recordGenerationMetrics(inputImages: Int, outputTokens: Int, generationTime: TimeInterval, batteryBefore: Int) {
        let tokensPerSecond = Double(outputTokens) / generationTime
        let memoryUsage = currentMemoryUsage

        let metrics = GenerationMetrics(
            timestamp: Date(),
            modelIdentifier: preferredModel,
            inputImageCount: inputImages,
            outputTokenCount: outputTokens,
            generationTime: generationTime,
            tokensPerSecond: tokensPerSecond,
            memoryUsageMB: memoryUsage,
            batteryLevelBefore: batteryBefore,
            batteryLevelAfter: batteryLevel,
            thermalState: thermalState
        )

        generationHistory.append(metrics)

        // Keep only last 50 generations for performance
        if generationHistory.count > 50 {
            generationHistory.removeFirst()
        }

        // Update aggregates
        totalGenerations += 1
        totalTokensGenerated += outputTokens

        let allGenerationTimes = generationHistory.map { $0.generationTime }
        averageGenerationTime = allGenerationTimes.reduce(0, +) / Double(allGenerationTimes.count)

        let allTokensPerSecond = generationHistory.map { $0.tokensPerSecond }
        averageTokensPerSecond = allTokensPerSecond.reduce(0, +) / Double(allTokensPerSecond.count)
    }

    // MARK: - Model Management

    /// Initializes the preferred AI model
    private func initializeModel() async {
        do {
            let startTime = Date()
            os_signpost(.begin, log: signpostLog, name: "ModelInit", "Model=%{public}@", preferredModel.displayName)

            // Use user-configured max tokens, with performance mode override
            let maxTokens = isPerformanceModeEnabled ? min(1200, userMaxTokens) : userMaxTokens
            currentModel = try OnDeviceModel(modelIdentifier: preferredModel, maxTokens: maxTokens)
            currentSession = try AIChatSession(model: currentModel!)

            let endTime = Date()
            modelInitializationTime = endTime.timeIntervalSince(startTime)

            accelerationMode = SME2Support.activeMode
            isInitialized = true
            initializationError = nil

            os_signpost(.end, log: signpostLog, name: "ModelInit")
            NSLog("AI model \(preferredModel.displayName) initialized in \(modelInitializationTime)s (perfMode=\(isPerformanceModeEnabled))")
        } catch {
            initializationError = "Failed to initialize on-device LLM: \(error.localizedDescription)"
            isInitialized = false
            NSLog("Model initialization error: \(error)")
        }
    }

    /// Checks if the service is ready for inference
    func isReady() -> Bool {
        return isInitialized && currentSession != nil
    }

    /// Loads `modelIdentifier` if no model is loaded yet, e.g. right after it was downloaded
    /// or when the user retries after a failed load. Does nothing once a model is loaded.
    func loadModelIfNeeded(_ modelIdentifier: ModelIdentifier) async {
        guard !isInitialized else { return }
        preferredModel = modelIdentifier
        await initializeModel()
    }

    /// Switch to a different model
    /// - Parameter modelIdentifier: The model to switch to
    func switchModel(to modelIdentifier: ModelIdentifier) async {
        guard modelIdentifier != preferredModel else {
            NSLog("Already using model: \(modelIdentifier.displayName)")
            return
        }
        
        NSLog("Switching model from \(preferredModel.displayName) to \(modelIdentifier.displayName)")
        
        // Update preferred model
        preferredModel = modelIdentifier
        
        // Reset initialization state
        isInitialized = false
        initializationError = nil
        currentModel = nil
        currentSession = nil
        
        // Initialize new model
        await initializeModel()
    }

    // MARK: - LaTeX Generation

    /// Generates LaTeX from images using the on-device LLM
    /// - Parameters:
    ///   - images: Array of UIImages to convert
    ///   - additionalPrompt: Optional additional context or instructions
    ///   - status: Status object to update with progress
    /// - Returns: Generated LaTeX string
    func generateLaTeX(from images: [UIImage],
                       additionalPrompt: String? = nil,
                       status: GenerationStatus) async throws -> String {
        guard isReady() else {
            throw OnDeviceLLMError.notInitialized
        }
        guard !isBenchmarking else {
            throw OnDeviceLLMError.generationFailed("The SME2 benchmark is running. Try again when it finishes.")
        }
        isGenerating = true
        defer { isGenerating = false }

        let startTime = Date()
        let batteryBefore = batteryLevel
        let initialMemory = currentMemoryUsage

        await MainActor.run {
            status.statusMessage = "Processing images with on-device AI..."
            status.progress = 0.1
            streamingLaTeX = "" // Clear previous stream
            currentTokensPerSecond = 0.0 // Reset real-time metric
        }

        // Create a new session for this generation task.
        // Transcription uses greedy decoding (topK = 1) so the same photo always gives the same LaTeX;
        // temperature and topP have no effect then. The user's sampling settings apply to refinement only.
        NSLog("[OnDeviceLLM] Creating vision-enabled session (perfMode=\(isPerformanceModeEnabled))")
        NSLog("[OnDeviceLLM] Parameters: greedy (topK=1)")
        let session = try AIChatSession(
            model: currentModel!,
            topK: 1,
            topP: 1.0,
            temperature: 1.0,
            enableVisionModality: true
        )
        NSLog("[OnDeviceLLM] Session created with vision modality enabled")

        // Downscale images in parallel (Accelerate) for lower memory and faster vision path
        os_signpost(.begin, log: signpostLog, name: "PreprocessImages")
        // 768 is the vision encoder's largest native input size; larger images only cost time and memory.
        let maxDimension = isPerformanceModeEnabled ? 512 : 768
        let processedCGImages: [CGImage] = await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, img) in images.enumerated() {
                group.addTask(priority: .userInitiated) {
                    // cgImage ignores imageOrientation, so portrait camera photos would reach the model sideways.
                    guard let cg = uprightCGImage(img) else { return (index, nil) }
                    return (index, downscaleCGImageAccelerate(cg, maxDimension: maxDimension) ?? cg)
                }
            }
            // Task groups finish in any order; keep the user's page order.
            var byIndex: [Int: CGImage] = [:]
            while let (index, img) = await group.next() {
                if let img { byIndex[index] = img }
            }
            return byIndex.keys.sorted().compactMap { byIndex[$0] }
        }
        os_signpost(.end, log: signpostLog, name: "PreprocessImages")

        NSLog("[OnDeviceLLM] Adding \(processedCGImages.count) images to query")
        for (index, cgImage) in processedCGImages.enumerated() {
            NSLog("[OnDeviceLLM] Adding image \(index + 1): \(cgImage.width)x\(cgImage.height)")
            try session.addImageToQuery(image: cgImage)
            await MainActor.run {
                status.statusMessage = "Processing image \(index + 1) of \(processedCGImages.count)..."
                status.progress = 0.1 + (0.3 * Double(index + 1) / Double(processedCGImages.count))
            }
        }
        NSLog("[OnDeviceLLM] All images added successfully")

        await MainActor.run {
            status.statusMessage = "Generating LaTeX with on-device AI..."
            status.progress = 0.5
        }

        // Create the prompt for LaTeX generation
        let prompt = createLaTeXGenerationPrompt(additionalPrompt: additionalPrompt)
        NSLog("[OnDeviceLLM] Using prompt: \(prompt.prefix(200))...")

        // Generate LaTeX using streaming response (30fps throttled UI updates)
        let stream = try await session.generateLaTeX(prompt: prompt)
        var fullResponse = ""
        let generationStartTime = Date()
        var lastUIUpdate = Date.distantPast
        firstTokenLogged = false

        for try await chunk in stream {
            fullResponse += chunk

            // First token event
            if !firstTokenLogged && !chunk.isEmpty {
                os_signpost(.event, log: signpostLog, name: "FirstToken")
                firstTokenLogged = true
            }

            let now = Date()
            if now.timeIntervalSince(lastUIUpdate) >= (1.0 / 30.0) {
                let elapsedTime = now.timeIntervalSince(generationStartTime)
                let estimatedTokens = max(fullResponse.count / 4, 1) // ~4 chars per token
                let tokensPerSec = elapsedTime > 0 ? Double(estimatedTokens) / elapsedTime : 0

                await MainActor.run {
                    streamingLaTeX = fullResponse // Update streaming display
                    currentTokensPerSecond = tokensPerSec // Update real-time tokens/sec
                    status.statusMessage = "Generating LaTeX... (\(fullResponse.count) characters)"
                    status.progress = 0.5 + (0.4 * min(1.0, Double(fullResponse.count) / 2000.0))
                }
                lastUIUpdate = now
            }
        }

        let endTime = Date()
        let generationTime = endTime.timeIntervalSince(startTime)

        await MainActor.run {
            status.statusMessage = "LaTeX generation complete"
            status.progress = 1.0
        }

        // Extract LaTeX content from response (remove any extra text)
        let latexResult = extractLaTeXFromResponse(fullResponse)

        // Estimate token count using model tokenizer; fallback to char/4 if unavailable
        let estimatedTokens = (try? session.sizeInTokens(text: fullResponse)) ?? (fullResponse.count / 4)

        // Record performance metrics
        recordGenerationMetrics(
            inputImages: images.count,
            outputTokens: estimatedTokens,
            generationTime: generationTime,
            batteryBefore: batteryBefore
        )

        return latexResult
    }

    /// Refines existing LaTeX based on user feedback using on-device LLM
    /// - Parameters:
    ///   - currentLaTeX: The existing LaTeX to refine
    ///   - userFeedback: User's refinement instructions
    ///   - status: Status object to update with progress
    /// - Returns: Refined LaTeX string
    /// - Note: This method does NOT re-process images, only refines the existing LaTeX code
    func refineLaTeX(currentLaTeX: String,
                     userFeedback: String,
                     status: GenerationStatus) async throws -> String {
        guard isReady() else {
            throw OnDeviceLLMError.notInitialized
        }
        guard !isBenchmarking else {
            throw OnDeviceLLMError.generationFailed("The SME2 benchmark is running. Try again when it finishes.")
        }
        isGenerating = true
        defer { isGenerating = false }

        let startTime = Date()
        let batteryBefore = batteryLevel

        await MainActor.run {
            status.statusMessage = "Preparing refinement with on-device AI..."
            status.progress = 0.1
            streamingLaTeX = "" // Clear previous stream
            currentTokensPerSecond = 0.0 // Reset real-time metric
        }

        // Create a new session for refinement (text-only, no images) using user settings
        let temp = isPerformanceModeEnabled ? min(userTemperature, 0.6) : userTemperature
        let tP = isPerformanceModeEnabled ? min(userTopP, 0.95) : userTopP
        let tK = isPerformanceModeEnabled ? max(userTopK, 60) : userTopK
        
        NSLog("[OnDeviceLLM] Creating text-only session for refinement")
        NSLog("[OnDeviceLLM] Parameters: temp=\(temp), topP=\(tP), topK=\(tK)")
        let session = try AIChatSession(
            model: currentModel!,
            topK: tK,
            topP: tP,
            temperature: temp,
            enableVisionModality: false
        )

        await MainActor.run {
            status.statusMessage = "Refining LaTeX with on-device AI..."
            status.progress = 0.3
        }

        // Create refinement prompt
        let prompt = createLaTeXRefinementPrompt(currentLaTeX: currentLaTeX, userFeedback: userFeedback)

        // Generate refined LaTeX (30fps throttled updates)
        let stream = try await session.generateLaTeX(prompt: prompt)
        var fullResponse = ""
        let generationStartTime = Date()
        var lastUIUpdate = Date.distantPast
        firstTokenLogged = false

        for try await chunk in stream {
            fullResponse += chunk

            if !firstTokenLogged && !chunk.isEmpty {
                os_signpost(.event, log: signpostLog, name: "FirstToken(Refine)")
                firstTokenLogged = true
            }

            let now = Date()
            if now.timeIntervalSince(lastUIUpdate) >= (1.0 / 30.0) {
                let elapsedTime = now.timeIntervalSince(generationStartTime)
                let estimatedTokens = max(fullResponse.count / 4, 1)
                let tokensPerSec = elapsedTime > 0 ? Double(estimatedTokens) / elapsedTime : 0

                await MainActor.run {
                    streamingLaTeX = fullResponse // Update streaming display
                    currentTokensPerSecond = tokensPerSec // Update real-time tokens/sec
                    status.statusMessage = "Refining LaTeX... (\(fullResponse.count) characters)"
                    status.progress = 0.3 + (0.6 * min(1.0, Double(fullResponse.count) / 2000.0))
                }
                lastUIUpdate = now
            }
        }

        let endTime = Date()
        let generationTime = endTime.timeIntervalSince(startTime)

        await MainActor.run {
            status.statusMessage = "LaTeX refinement complete"
            status.progress = 1.0
        }

        let latexResult = extractLaTeXFromResponse(fullResponse)

        // Estimate token count for refinement using tokenizer when possible
        let estimatedTokens = (try? session.sizeInTokens(text: fullResponse)) ?? (fullResponse.count / 4)

        // Record performance metrics for refinement (0 images since we're only refining LaTeX)
        recordGenerationMetrics(
            inputImages: 0,
            outputTokens: estimatedTokens,
            generationTime: generationTime,
            batteryBefore: batteryBefore
        )

        return latexResult
    }

    // MARK: - SME2 Benchmark

    /// Runs one warm-up and `measuredRuns` measured generations of `image` on the already-loaded model
    /// (no second LlmInference, which would double memory). Uses the normal generation prompt with fixed
    /// greedy settings so SME2 and NEON launches are comparable. Runs are not added to the generation history.
    func runSME2Benchmark(image: CGImage,
                          measuredRuns: Int,
                          progress: (String) -> Void) async throws -> [SME2BenchmarkRun] {
        guard isReady(), let model = currentModel else {
            throw OnDeviceLLMError.notInitialized
        }
        guard !isGenerating, !isBenchmarking else {
            throw OnDeviceLLMError.generationFailed("Another generation is running. Try again when it finishes.")
        }
        isBenchmarking = true
        defer { isBenchmarking = false }

        // Same downscale as generateLaTeX, at a fixed size so Performance Mode doesn't change the input.
        let input = downscaleCGImageAccelerate(image, maxDimension: SME2Benchmark.imageMaxDimension) ?? image
        NSLog("[SME2Benchmark] Mode=\(SME2Support.activeMode?.displayName ?? "unknown"), image \(input.width)x\(input.height)")

        var runs: [SME2BenchmarkRun] = []
        for index in 0...measuredRuns {
            progress(index == 0 ? "Warm-up run..." : "Run \(index) of \(measuredRuns)...")
            let run = try await runBenchmarkGeneration(model: model, image: input)
            NSLog("[SME2Benchmark] \(index == 0 ? "warm-up" : "run \(index)"): ttft=\(run.timeToFirstTokenSeconds)s decode=\(run.decodeTokensPerSecond) tok/s total=\(run.totalSeconds)s tokens=\(run.outputTokens) peak=\(run.peakMemoryMB) MB")
            if index > 0 {
                runs.append(run)
            }
        }
        return runs
    }

    private func runBenchmarkGeneration(model: OnDeviceModel, image: CGImage) async throws -> SME2BenchmarkRun {
        // Session creation (~3 s) is not part of any timing, as in the research harness.
        let session = try AIChatSession(
            model: model,
            topK: 1,
            topP: 1,
            temperature: 1,
            randomSeed: 0,
            enableVisionModality: true
        )
        let prompt = createLaTeXGenerationPrompt(additionalPrompt: nil)

        let memorySampler = PeakMemorySampler()
        memorySampler.start()
        defer { memorySampler.stop() }
        let thermalBefore = ProcessInfo.processInfo.thermalState

        let imageStart = ProcessInfo.processInfo.systemUptime
        try session.addImageToQuery(image: image)

        let generateStart = ProcessInfo.processInfo.systemUptime
        let stream = try await session.generateLaTeX(prompt: prompt)
        var fullResponse = ""
        var firstChunkTime: TimeInterval?
        for try await chunk in stream {
            if firstChunkTime == nil && !chunk.isEmpty {
                firstChunkTime = ProcessInfo.processInfo.systemUptime
            }
            fullResponse += chunk
        }
        let endTime = ProcessInfo.processInfo.systemUptime

        memorySampler.sample()
        let thermalAfter = ProcessInfo.processInfo.thermalState
        let outputTokens = (try? session.sizeInTokens(text: fullResponse)) ?? 0
        let firstChunk = firstChunkTime ?? endTime
        let decodeSeconds = endTime - firstChunk

        return SME2BenchmarkRun(
            timeToFirstTokenSeconds: firstChunk - generateStart,
            decodeTokensPerSecond: outputTokens > 1 && decodeSeconds > 0 ? Double(outputTokens - 1) / decodeSeconds : 0,
            totalSeconds: endTime - imageStart,
            outputTokens: outputTokens,
            peakMemoryMB: memorySampler.peakMB,
            thermalState: thermalAfter.rawValue > thermalBefore.rawValue ? thermalAfter : thermalBefore
        )
    }

    // MARK: - Private Helper Methods

    private func createLaTeXGenerationPrompt(additionalPrompt: String?) -> String {
        let basePrompt = """
        Look at the image(s) I provided above. What text, equations, or content do you see in the image?

        Transcribe it into this LaTeX format:

        \\documentclass{article}
        \\usepackage{amsmath}
        \\usepackage{amssymb}
        \\begin{document}

        [transcribe the actual content from the image here]

        \\end{document}

        Important:
        - Only transcribe what you actually see in the provided image
        - Use $ $ for inline math, \\[ \\] for display math
        - Use \\textbf{} for bold, \\textit{} for italic
        - If there's a diagram, write [Figure: description]
        - Do NOT make up example content
        - Do NOT include explanations, only LaTeX code
        """

        if let additional = additionalPrompt, !additional.isEmpty {
            return basePrompt + "\n\n" + additional
        }

        return basePrompt
    }

    private func createLaTeXRefinementPrompt(currentLaTeX: String, userFeedback: String) -> String {
        return """
        You are a LaTeX transcription tool. Refine the following LaTeX code based on user feedback.

        Current LaTeX:
        ```
        \(currentLaTeX)
        ```

        User feedback: \(userFeedback)

        Requirements:
        - Make the requested changes
        - Use ONLY \\documentclass{article} with \\usepackage{amsmath} and \\usepackage{amssymb}
        - Do NOT use: \\includegraphics, \\geometry, \\pagestyle, \\fancyhdr, \\fancyhead, \\fancyfoot, \\renewcommand, tabular, table, tikz, tikzpicture, or any other packages
        - Do NOT add \\section, \\subsection, or explanatory text about the LaTeX code itself
        - For math: Use ONLY \\[ \\] for display math and $ $ for inline math
        - NEVER use \\begin{equation}, \\begin{align}, \\begin{gather}, \\begin{multline}, or ANY \\begin{}...\\end{} environments
        - Keep it minimal and direct - just the content
        - Return ONLY the refined LaTeX code, no explanations

        Refined LaTeX:
        """
    }

    private func extractLaTeXFromResponse(_ response: String) -> String {
        // Remove markdown code blocks if present
        var latex = response
            .replacingOccurrences(of: "```latex", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Ensure it starts with \documentclass if it doesn't already
        if !latex.hasPrefix("\\documentclass") {
            // Try to find LaTeX content within the response
            if let latexStart = latex.firstIndex(of: "\\") {
                latex = String(latex[latexStart...])
            }
        }

        return latex
    }

}

// MARK: - Error Types
enum OnDeviceLLMError: LocalizedError {
    case notInitialized
    case modelNotAvailable
    case invalidImage
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "On-device AI is not initialized. Please wait for model loading to complete."
        case .modelNotAvailable:
            return "Required AI model is not available on this device."
        case .invalidImage:
            return "Invalid image provided for processing."
        case .generationFailed(let reason):
            return "AI generation failed: \(reason)"
        }
    }
}

// MARK: - Global Image Helpers (non-main-actor)

/// Returns pixels in display orientation. `UIImage.cgImage` is the raw sensor buffer, which for iPhone
/// portrait photos is stored sideways with an orientation flag the model never sees.
nonisolated private func uprightCGImage(_ image: UIImage) -> CGImage? {
    guard let cg = image.cgImage else { return nil }
    guard image.imageOrientation != .up else { return cg }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.cgImage ?? cg
}

private func downscaleCGImageAccelerate(_ src: CGImage, maxDimension: Int) -> CGImage? {
    let width = src.width
    let height = src.height
    let maxSide = max(width, height)
    guard maxSide > maxDimension else { return src }

    let scale = Double(maxDimension) / Double(maxSide)
    let dstW = Int(Double(width) * scale)
    let dstH = Int(Double(height) * scale)

    let colorSpace = CGColorSpaceCreateDeviceRGB()  // must outlive `format`, which holds it unretained
    var format = vImage_CGImageFormat(
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        colorSpace: Unmanaged.passUnretained(colorSpace),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent
    )

    var srcBuf = vImage_Buffer()
    var dstBuf = vImage_Buffer()
    defer { free(srcBuf.data) }

    guard vImageBuffer_InitWithCGImage(&srcBuf, &format, nil, src, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
    guard vImageBuffer_Init(&dstBuf, vImagePixelCount(dstH), vImagePixelCount(dstW), format.bitsPerPixel, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }

    vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))
    // With kvImageNoAllocate the CGImage takes ownership of dstBuf.data and free()s it when released
    // (vImage_Utilities.h). Freeing it here as well left the model reading freed pixels.
    guard let image = vImageCreateCGImageFromBuffer(&dstBuf, &format, nil, nil, vImage_Flags(kvImageNoAllocate), nil)?.takeRetainedValue() else {
        free(dstBuf.data)
        return nil
    }
    return image
}
