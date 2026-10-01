//
//  BenchmarkRunner.swift
//  Pic2PDF — research/arm_sme2_benchmark harness
//
//  Headless, UI-free benchmark of the real inference path (LlmInference +
//  Session + addImage + generateResponseAsync) with fixed inputs and greedy
//  decoding. Activated when the process is launched with PIC2PDF_BENCH=1.
//  Emits one JSON object per line to stdout (bridged by `devicectl --console`)
//  and to Documents/bench/<run_id>.jsonl on the device.
//
//  Configuration via environment:
//    BENCH_SME2=0|1        flip the XNNPACK SME2 gate before first init
//    BENCH_RUNS=N          measured runs in this process (default 5)
//    BENCH_WARMUP=N        warm-up runs excluded from stats (default 1)
//    BENCH_MODEL=gemma-3n-E2B-it-int4 | gemma-3n-E4B-it-int4
//    BENCH_MAX_TOKENS=N    LlmInference maxTokens (context cap, default 1024)
//    BENCH_RUN_ID=string   label written into every record
//    BENCH_SLEEP=seconds   cool-down after each iteration (default 2)
//

import Foundation
import UIKit
import MediaPipeTasksGenAI
import ZIPFoundation

// C shim (bench_xnn.c) — no bridging header, resolved via silgen names.
@_silgen_name("bench_xnn_set_sme2") private func c_bench_xnn_set_sme2(_ v: Int32)
@_silgen_name("bench_xnn_sme2_default") private func c_bench_xnn_sme2_default() -> Int32
@_silgen_name("bench_xnn_hw_flags") private func c_bench_xnn_hw_flags(
    _ arch: UnsafeMutablePointer<UInt64>, _ dot: UnsafeMutablePointer<Int32>,
    _ i8mm: UnsafeMutablePointer<Int32>, _ sme: UnsafeMutablePointer<Int32>,
    _ sme2: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("bench_sysctl_int") private func c_bench_sysctl_int(_ name: UnsafePointer<CChar>) -> Int32
@_silgen_name("bench_sysctl_str") private func c_bench_sysctl_str(
    _ name: UnsafePointer<CChar>, _ out: UnsafeMutablePointer<CChar>, _ cap: Int) -> Int32

@_silgen_name("probe_sk_copy") private func c_probe_sk_copy(_ img: CGImage, _ ct: Int32, _ at: Int32, _ r: UnsafeMutablePointer<Double>, _ g: UnsafeMutablePointer<Double>, _ b: UnsafeMutablePointer<Double>, _ a: UnsafeMutablePointer<Double>) -> Int32
@_silgen_name("probe_cg_copy") private func c_probe_cg_copy(_ img: CGImage, _ r: UnsafeMutablePointer<Double>, _ g: UnsafeMutablePointer<Double>, _ b: UnsafeMutablePointer<Double>, _ a: UnsafeMutablePointer<Double>) -> Int32

@_silgen_name("probe_c_api") private func c_probe_c_api(_ model: UnsafePointer<CChar>, _ enc: UnsafePointer<CChar>, _ adp: UnsafePointer<CChar>, _ cache: UnsafePointer<CChar>, _ backend: Int32, _ img: CGImage?, _ prompt: UnsafePointer<CChar>, _ out: UnsafeMutablePointer<CChar>, _ cap: Int) -> Int32
enum Bench {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["PIC2PDF_BENCH"] == "1" }

    // MARK: - Memory / system probes

    struct Mem: Encodable {
        let rss_mb: Double
        let rss_peak_mb: Double
        let footprint_mb: Double
        let footprint_peak_mb: Double
    }

    static func mem() -> Mem {
        var basic = mach_task_basic_info()
        var bcount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr1 = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &bcount)
            }
        }
        var vm = task_vm_info_data_t()
        var vcount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr2 = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vcount)
            }
        }
        let mb = 1024.0 * 1024.0
        return Mem(
            rss_mb: kr1 == KERN_SUCCESS ? Double(basic.resident_size) / mb : -1,
            rss_peak_mb: kr1 == KERN_SUCCESS ? Double(basic.resident_size_max) / mb : -1,
            footprint_mb: kr2 == KERN_SUCCESS ? Double(vm.phys_footprint) / mb : -1,
            footprint_peak_mb: kr2 == KERN_SUCCESS ? Double(vm.ledger_phys_footprint_peak) / mb : -1
        )
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func sysctlInt(_ k: String) -> Int { Int(k.withCString { c_bench_sysctl_int($0) }) }
    static func sysctlStr(_ k: String) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        _ = k.withCString { c_bench_sysctl_str($0, &buf, buf.count) }
        return String(cString: buf)
    }

    static func cpuFeatures() -> [String: Int] {
        let keys = ["hw.optional.AdvSIMD", "hw.optional.arm.FEAT_DotProd", "hw.optional.arm.FEAT_I8MM",
                    "hw.optional.arm.FEAT_BF16", "hw.optional.arm.FEAT_FP16", "hw.optional.arm.FEAT_SME",
                    "hw.optional.arm.FEAT_SME2", "hw.optional.arm.FEAT_SME2p1", "hw.optional.arm.SME_I8I32",
                    "hw.optional.arm.SME_F32F32", "hw.optional.arm.sme_max_svl_b",
                    "hw.optional.arm.FEAT_SVE", "hw.ncpu", "hw.physicalcpu", "hw.perflevel0.physicalcpu",
                    "hw.perflevel1.physicalcpu", "hw.memsize", "hw.cpufamily"]
        var out: [String: Int] = [:]
        for k in keys { out[k] = sysctlInt(k) }
        return out
    }

    // MARK: - Records

    struct Env: Encodable {
        let record = "env"
        let run_id: String
        let sme2_requested: Int
        let sme2_default_before_init: Int
        let model: String
        let machine: String
        let cpu_brand: String
        let os_version: String
        let cpu_features: [String: Int]
        let thermal_at_start: String
        let is_low_power_mode: Bool
        let battery_level: Float
        let battery_state: Int
        let mem_before_load: Mem
        let process_start_iso: String
        let bundle_build: String
    }

    struct HW: Encodable {
        let record = "xnn_hw"
        let run_id: String
        let arch_flags_hex: String
        let use_arm_neon_dot: Int
        let use_arm_neon_i8mm: Int
        let use_arm_sme: Int
        let use_arm_sme2: Int
        let sme2_default_after_init: Int
    }

    struct Init: Encodable {
        let record = "init"
        let run_id: String
        let model_bytes: Int64
        let vision_encoder_bytes: Int64
        let vision_adapter_bytes: Int64
        let extract_s: Double
        let llm_init_s: Double
        let llm_metrics_init_s: Double
        let session_init_s: Double
        let xnn_cache_existed: Bool
        let xnn_cache_bytes_before: Int64
        let xnn_cache_bytes_after: Int64
        let model_path: String
        let mem_after_load: Mem
        let thermal_after_load: String
    }

    struct Run: Encodable {
        let record = "run"
        let run_id: String
        let sme2: Int
        let iter: Int
        let warmup: Bool
        let image_px: String
        let prompt_tokens: Int
        let session_create_s: Double
        let add_image_s: Double
        let add_query_s: Double
        let ttft_s: Double            // generate call -> first non-empty chunk
        let decode_s: Double          // first chunk -> stream end
        let e2e_s: Double             // session create -> stream end
        let gen_s: Double             // generate call -> stream end
        let mp_response_generation_s: Double
        let output_tokens: Int        // via session.sizeInTokens (runtime tokenizer)
        let output_chars: Int
        let chunks: Int
        let chunk_t_s: [Double]       // arrival time of each chunk relative to generate call
        let chunk_chars: [Int]        // characters in each chunk
        let first_chunk_tokens: Int   // tokens in the first chunk (TTFT granularity)
        let decode_tok_s: Double      // (output_tokens - 1) / decode_s
        let output_sha256_prefix: String
        let output_text: String
        let mem_before: Mem
        let mem_after: Mem
        let mem_peak_during_footprint_mb: Double
        let thermal_before: String
        let thermal_after: String
        let ts_iso: String
    }

    // MARK: - Output

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static var logHandle: FileHandle?

    static func emit<T: Encodable>(_ v: T) {
        let enc = JSONEncoder()
        guard let d = try? enc.encode(v), let s = String(data: d, encoding: .utf8) else { return }
        print("BENCHJSON " + s)
        fflush(stdout)
        if logHandle == nil {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bench")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let runId = ProcessInfo.processInfo.environment["BENCH_RUN_ID"] ?? "run"
            let url = dir.appendingPathComponent("\(runId).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            logHandle = try? FileHandle(forWritingTo: url)
            logHandle?.seekToEndOfFile()
        }
        logHandle?.write((s + "\n").data(using: .utf8)!)
    }

    static func log(_ s: String) { print("BENCH " + s); fflush(stdout) }

    // MARK: - Main

    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let runId = env["BENCH_RUN_ID"] ?? "run"
        let sme2 = Int(env["BENCH_SME2"] ?? "0") ?? 0
        let runs = Int(env["BENCH_RUNS"] ?? "5") ?? 5
        let warmup = Int(env["BENCH_WARMUP"] ?? "1") ?? 1
        let modelName = env["BENCH_MODEL"] ?? "gemma-3n-E2B-it-int4"
        let maxTokens = Int(env["BENCH_MAX_TOKENS"] ?? "1024") ?? 1024
        let processStart = Date()

        UIDevice.current.isBatteryMonitoringEnabled = true

        // ---- Gate: must happen before ANY XNNPACK init in this process.
        let defaultBefore = Int(c_bench_xnn_sme2_default())
        if sme2 != 0 { c_bench_xnn_set_sme2(1) }
        log("xnn_enable_arm_sme2_default before init = \(defaultBefore); requested sme2=\(sme2)")

        emit(Env(run_id: runId, sme2_requested: sme2, sme2_default_before_init: defaultBefore,
                 model: modelName, machine: sysctlStr("hw.machine"), cpu_brand: sysctlStr("machdep.cpu.brand_string"),
                 os_version: ProcessInfo.processInfo.operatingSystemVersionString,
                 cpu_features: cpuFeatures(), thermal_at_start: thermal(),
                 is_low_power_mode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                 battery_level: UIDevice.current.batteryLevel, battery_state: UIDevice.current.batteryState.rawValue,
                 mem_before_load: mem(), process_start_iso: iso.string(from: processStart),
                 bundle_build: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"))

        // ---- Locate model (Documents/Models/<name>.task, same as the app).
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let canonicalURL = docs.appendingPathComponent("Models/\(modelName).task")
        guard fm.fileExists(atPath: canonicalURL.path) else {
            log("FATAL model not found at \(canonicalURL.path)"); exit(2)
        }
        // XNNPACK writes its packed-weight cache to "<modelPath>.xnnpack_cache" and the
        // packed layout differs between NEON and SME2 kernels (the cache is NOT keyed by
        // ISA; loading a NEON-built cache with SME2 enabled aborts in
        // xnn_reserve_space_in_weights_cache). Give each configuration its own model path
        // via a hard link so each gets its own cache, with identical model bytes.
        let modelURL: URL
        if sme2 != 0 {
            let dir = docs.appendingPathComponent("Models/sme2", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            modelURL = dir.appendingPathComponent("\(modelName).task")
            if !fm.fileExists(atPath: modelURL.path) {
                do { try fm.linkItem(at: canonicalURL, to: modelURL) } catch { log("FATAL hardlink: \(error)"); exit(2) }
            }
        } else {
            modelURL = canonicalURL
        }
        let cacheURL = URL(fileURLWithPath: modelURL.path + ".xnnpack_cache")
        let cacheExisted = fm.fileExists(atPath: cacheURL.path)
        let cacheBytesBefore = (try? fm.attributesOfItem(atPath: cacheURL.path)[.size] as? Int64) ?? 0
        log("model=\(modelURL.lastPathComponent) cache_existed=\(cacheExisted) cache_bytes=\(cacheBytesBefore)")
        let modelBytes = (try? fm.attributesOfItem(atPath: modelURL.path)[.size] as? Int64) ?? -1

        // Vision components: extracted next to the model (same as OnDeviceModel does).
        let cache = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let encURL = cache.appendingPathComponent("TF_LITE_VISION_ENCODER")
        let adpURL = cache.appendingPathComponent("TF_LITE_VISION_ADAPTER")
        let tExtract0 = Date()
        if !fm.fileExists(atPath: encURL.path) || !fm.fileExists(atPath: adpURL.path) {
            do {
                let archive = try Archive(url: modelURL, accessMode: .read)
                for (name, dst) in [("TF_LITE_VISION_ENCODER", encURL), ("TF_LITE_VISION_ADAPTER", adpURL)] {
                    guard let entry = archive[name] else { log("FATAL missing \(name) in archive"); exit(3) }
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    _ = try archive.extract(entry, to: dst)
                }
            } catch { log("FATAL extract: \(error)"); exit(3) }
        }
        let extractS = Date().timeIntervalSince(tExtract0)
        let encBytes = (try? fm.attributesOfItem(atPath: encURL.path)[.size] as? Int64) ?? -1
        let adpBytes = (try? fm.attributesOfItem(atPath: adpURL.path)[.size] as? Int64) ?? -1

        if let be = env["BENCH_C_API_BACKEND"], let backend = Int32(be) {
            let imgPath = env["BENCH_IMAGE_PATH"] ?? ""
            let cgImg = UIImage(contentsOfFile: imgPath)?.cgImage
            let prompt = env["BENCH_PROMPT"] ?? "What is the main color of this image? Answer with one word."
            var out = [CChar](repeating: 0, count: 4096)
            let t0 = Date()
            let rc = c_probe_c_api(modelURL.path, encURL.path, adpURL.path, NSTemporaryDirectory(), backend, cgImg, prompt, &out, out.count)
            log("CPROBE backend=\(backend) image=\(cgImg == nil ? "none" : imgPath) rc=\(rc) secs=\(String(format: "%.1f", Date().timeIntervalSince(t0))) reply=\(String(cString: out).debugDescription)")
            log("DONE"); exit(0)
        }

        // ---- Model init (this is where XNNPACK hardware config is first resolved).
        let opts = LlmInference.Options(modelPath: modelURL.path)
        opts.maxTokens = maxTokens
        opts.visionEncoderPath = encURL.path
        opts.visionAdapterPath = adpURL.path
        opts.maxImages = 1
        let tInit0 = Date()
        let llm: LlmInference
        do { llm = try LlmInference(options: opts) } catch { log("FATAL LlmInference: \(error)"); exit(4) }
        let llmInitS = Date().timeIntervalSince(tInit0)

        // Read back XNNPACK's decision.
        var arch: UInt64 = 0; var dot: Int32 = 0, i8mm: Int32 = 0, smeF: Int32 = 0, sme2F: Int32 = 0
        _ = c_bench_xnn_hw_flags(&arch, &dot, &i8mm, &smeF, &sme2F)
        emit(HW(run_id: runId, arch_flags_hex: String(format: "0x%llx", arch), use_arm_neon_dot: Int(dot),
                use_arm_neon_i8mm: Int(i8mm), use_arm_sme: Int(smeF), use_arm_sme2: Int(sme2F),
                sme2_default_after_init: Int(c_bench_xnn_sme2_default())))
        log("XNNPACK hw: arch=0x\(String(arch, radix: 16)) dot=\(dot) i8mm=\(i8mm) sme=\(smeF) sme2=\(sme2F)")

        // Session creation latency (measured once at init, and again per run).
        let tSess0 = Date()
        do { _ = try makeSession(llm) } catch { log("FATAL session: \(error)"); exit(5) }
        let sessInitS = Date().timeIntervalSince(tSess0)

        emit(Init(run_id: runId, model_bytes: modelBytes, vision_encoder_bytes: encBytes, vision_adapter_bytes: adpBytes,
                  extract_s: extractS, llm_init_s: llmInitS, llm_metrics_init_s: llm.metrics.initializationTimeInSeconds,
                  session_init_s: sessInitS, xnn_cache_existed: cacheExisted, xnn_cache_bytes_before: cacheBytesBefore,
                  xnn_cache_bytes_after: (try? fm.attributesOfItem(atPath: cacheURL.path)[.size] as? Int64) ?? 0,
                  model_path: modelURL.path, mem_after_load: mem(), thermal_after_load: thermal()))

        // ---- Fixed workload.
        // Probe overrides: BENCH_IMAGE_PATH (absolute), BENCH_PROMPT, BENCH_NO_IMAGE=1.
        let imagePath = env["BENCH_IMAGE_PATH"] ?? Bundle.main.url(forResource: "bench_math", withExtension: "png")?.path ?? ""
        guard let ui = UIImage(contentsOfFile: imagePath), let cg = ui.cgImage else {
            log("FATAL image missing at \(imagePath)"); exit(6)
        }
        if env["BENCH_PIXEL_PROBE"] == "1" {
            var r = 0.0, g = 0.0, b = 0.0, a = 0.0
            let okCG = c_probe_cg_copy(cg, &r, &g, &b, &a)
            log(String(format: "PROBE plain CoreGraphics ok=%d mean bytes [%.1f %.1f %.1f %.1f]", okCG, r, g, b, a))
            for ct in [4, 6] { for at in [2, 3] {
                let ok = c_probe_sk_copy(cg, Int32(ct), Int32(at), &r, &g, &b, &a)
                log(String(format: "PROBE Skia colorType=%d alphaType=%d ok=%d mean bytes [%.1f %.1f %.1f %.1f]", ct, at, ok, r, g, b, a))
            } }
            log("DONE"); exit(0)
        }
        let noImage = env["BENCH_NO_IMAGE"] == "1"
        let prompt = env["BENCH_PROMPT"] ?? benchPrompt
        log("probe image=\(noImage ? "NONE" : imagePath) \(cg.width)x\(cg.height) bpc=\(cg.bitsPerComponent) bpp=\(cg.bitsPerPixel) alpha=\(cg.alphaInfo.rawValue)")

        for iter in 0..<(warmup + runs) {
            let isWarm = iter < warmup
            let memBefore = mem()
            let thermBefore = thermal()
            let t0 = Date()
            let session: LlmInference.Session
            do { session = try makeSession(llm) } catch { log("FATAL session: \(error)"); exit(5) }
            let tSess = Date().timeIntervalSince(t0)

            let tImg0 = Date()
            if !noImage { do { try session.addImage(image: cg) } catch { log("FATAL addImage: \(error)"); exit(7) } }
            let addImageS = Date().timeIntervalSince(tImg0)

            let tQ0 = Date()
            do { try session.addQueryChunk(inputText: prompt) } catch { log("FATAL addQuery: \(error)"); exit(8) }
            let addQueryS = Date().timeIntervalSince(tQ0)
            let promptTokens = (try? session.sizeInTokens(text: prompt)) ?? -1

            var text = ""
            var chunks = 0
            var chunkT: [Double] = []
            var chunkC: [Int] = []
            var firstChunk = ""
            var tFirst: Date? = nil
            let tGen0 = Date()
            var peakFootprint = memBefore.footprint_mb
            let sampler = Task.detached(priority: .utility) { () -> Double in
                var p = 0.0
                while !Task.isCancelled {
                    p = max(p, Bench.mem().footprint_mb)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                return p
            }
            do {
                for try await chunk in session.generateResponseAsync() {
                    chunks += 1
                    chunkT.append(Date().timeIntervalSince(tGen0)); chunkC.append(chunk.count)
                    if tFirst == nil && !chunk.isEmpty { tFirst = Date(); firstChunk = chunk }
                    text += chunk
                }
            } catch { log("FATAL generate: \(error)"); exit(9) }
            let tEnd = Date()
            sampler.cancel()
            peakFootprint = max(peakFootprint, await sampler.value)

            let ttft = (tFirst ?? tEnd).timeIntervalSince(tGen0)
            let decodeS = tEnd.timeIntervalSince(tFirst ?? tEnd)
            let outTok = (try? session.sizeInTokens(text: text)) ?? -1
            let sha = sha256Prefix(text)
            let rec = Run(run_id: runId, sme2: sme2, iter: iter, warmup: isWarm, image_px: "\(cg.width)x\(cg.height)",
                          prompt_tokens: promptTokens, session_create_s: tSess, add_image_s: addImageS, add_query_s: addQueryS,
                          ttft_s: ttft, decode_s: decodeS, e2e_s: tEnd.timeIntervalSince(t0), gen_s: tEnd.timeIntervalSince(tGen0),
                          mp_response_generation_s: session.metrics.responseGenerationTimeInSeconds,
                          output_tokens: outTok, output_chars: text.count, chunks: chunks,
                          chunk_t_s: chunkT, chunk_chars: chunkC,
                          first_chunk_tokens: (try? session.sizeInTokens(text: firstChunk)) ?? -1,
                          decode_tok_s: decodeS > 0 && outTok > 1 ? Double(outTok - 1) / decodeS : 0,
                          output_sha256_prefix: sha, output_text: text,
                          mem_before: memBefore, mem_after: mem(), mem_peak_during_footprint_mb: peakFootprint,
                          thermal_before: thermBefore, thermal_after: thermal(), ts_iso: iso.string(from: t0))
            emit(rec)
            log(String(format: "iter %d%@ ttft=%.3fs decode=%.3fs tok=%d (%.2f tok/s) e2e=%.3fs thermal=%@",
                       iter, isWarm ? " (warmup)" : "", ttft, decodeS, outTok, rec.decode_tok_s, rec.e2e_s, thermal()))
            // Cool-down between iterations so thermal state isn't cumulative within a process.
            let sleepS = Double(env["BENCH_SLEEP"] ?? "2") ?? 2
            try? await Task.sleep(nanoseconds: UInt64(sleepS * 1_000_000_000))
        }
        log("DONE")
        try? logHandle?.close()
        exit(0)
    }

    static func makeSession(_ llm: LlmInference) throws -> LlmInference.Session {
        let o = LlmInference.Session.Options()
        o.topk = 1            // greedy: deterministic output for a fixed image+prompt
        o.topp = 1.0
        o.temperature = 1.0   // irrelevant under top-k = 1
        o.randomSeed = 0
        o.enableVisionModality = true
        if ProcessInfo.processInfo.environment["BENCH_NO_IMAGE"] == "1" { o.enableVisionModality = false }
        return try LlmInference.Session(llmInference: llm, options: o)
    }

    // Same prompt as OnDeviceLLMService.createLaTeXGenerationPrompt (no additional prompt).
    static let benchPrompt = """
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

    static func sha256Prefix(_ s: String) -> String {
        // Tiny FNV-style stand-in avoided; use CryptoKit for a real digest.
        import_CryptoKit_sha256(s)
    }
}

import CryptoKit
private func import_CryptoKit_sha256(_ s: String) -> String {
    let d = SHA256.hash(data: Data(s.utf8))
    return d.map { String(format: "%02x", $0) }.joined().prefix(16).description
}
