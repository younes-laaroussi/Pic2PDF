# SME2-by-default release plan

Branch: `sme2-default` (off `main`). Target: on GitHub by **Oct 5, 2026**, App Store submission right after.

This file is written for an agent working **without Xcode, without an iPhone, and without the MediaPipe
binaries** (a Linux cloud session). Everything that was verified on the Mac and the iPhone is recorded here
so you don't need to re-derive it. Do the tasks marked **[cloud]**. Leave the tasks marked **[mac]** for later:
they need Xcode, CocoaPods and the physical iPhone 16 Pro Max.

Goal: get ~90% done in the cloud session. Code must be written carefully because **you cannot compile it**.
Prefer small, obviously-correct changes that follow the existing code style.

---

## 1. Requirements

1. SME2 **on by default** on devices that support it.
2. A **visible SME2 / NEON indicator** so people can see which path is running.
3. A **benchmark mode** so users can compare SME2 vs NEON on their own phone.
4. Plus **quality fixes** (decided by the user): greedy decoding and a smaller input image.

## 2. Verified facts (do not re-derive)

Measured on an iPhone 16 Pro Max (A18 Pro, iOS 27.0) on 2026-09-17. Full evidence lives on the
`research/arm-sme2-benchmark` branch (local only, not pushed).

- The app uses **MediaPipe Tasks GenAI 0.10.24** (CocoaPods `MediaPipeTasksGenAI` + `MediaPipeTasksGenAIC`).
  `MediaPipeTasksGenAIC` is a **static archive** linked into the app, containing XNNPACK + KleidiAI.
- XNNPACK decides SME2 in `init_hardware_config()`:
  `use_arm_sme2 = (xnn_enable_arm_sme2_default != 0) && cpuinfo.FEAT_SME2`.
  `xnn_enable_arm_sme2_default` is **0** and nothing in MediaPipe sets it, so the shipping app runs **NEON only**.
- `void xnn_internal_set_arm_sme2(int)` (present in the archive) sets that default, **but only before the first
  XNNPACK hardware-config init**. The first init locks the value to -1; later calls do nothing.
  → **SME2 can only be chosen once per process, before the model loads. A toggle needs an app restart.**
- After init, `xnn_init_hardware_config()` returns a struct whose **byte 0x15 is `use_arm_sme2`**
  (also 0x10 dot, 0x11 i8mm, 0x14 sme). Reading it tells you what XNNPACK *actually* chose.
- CPU support check: `sysctlbyname("hw.optional.arm.FEAT_SME2")` → 1 on A18/A18 Pro/M4 and later.
  This is the same sysctl XNNPACK's cpuinfo reads.
- **Weight cache crash:** XNNPACK writes packed weights to `<modelPath>.xnnpack_cache` on first init.
  The cache is **not keyed by ISA**. Loading a NEON-built cache with SME2 on aborts the process:
  `ERROR: Cannot reserve space in a cache that isn't building.` → SIGABRT.
  **Every existing App Store user has a NEON cache**, so shipping SME2 without handling this crashes them on launch.
  Fix: delete the cache whenever the SME2 mode differs from the mode that built it (costs ~8 s one-time rebuild).
- In the app, the model is copied to `Application Support/<modelIdentifier.fileName>` (see `OnDeviceModel.init`
  in `OnDeviceLLMService.swift`), so the cache is at
  `Application Support/<fileName>.xnnpack_cache` (e.g. `gemma-3n-E2B-it-int4.task.xnnpack_cache`, ~1.4 GB).
- Measured effect (Gemma 3n E2B, 18 vs 18 interleaved runs, 64 output tokens):
  time to first token 5.02 s → 2.96 s (−41%), image→last token 11.28 s → 8.67 s (−23%),
  decode 10.1 → 11.0 tok/s (+10%), memory unchanged (~1.5 GB after load, ~1.85 GB peak).
- Model load (warm cache) ≈ 3.1 s either way. Creating a `LlmInference.Session` ≈ 3 s **per generation**.

### MediaPipe Swift API you may use (from the 0.10.24 `.swiftinterface`)

```swift
LlmInference(options: LlmInference.Options)            // Options(modelPath:), .maxTokens, .visionEncoderPath,
                                                      // .visionAdapterPath, .maxImages, .maxTopk
llmInference.metrics.initializationTimeInSeconds
LlmInference.Session(llmInference:options:)            // Session.Options: .topk, .topp, .temperature,
                                                      // .randomSeed, .enableVisionModality
session.addImage(image: CGImage)
session.addQueryChunk(inputText: String)
session.generateResponseAsync() -> AsyncThrowingStream<String, Error>
session.sizeInTokens(text: String) -> Int              // real tokenizer; use for token counts
session.metrics.responseGenerationTimeInSeconds
```

## 3. Already done on this branch

- `Podfile`: `post_install` hook lifting pod deployment targets to iOS 17 (Xcode 27 rejects 12.0). Verified.
- `Pic2PDF/SME2/xnn_sme2.c`: C shim, **compiled and linked on the Mac** (unsigned Release build succeeded):
  - `int pic2pdf_cpu_has_sme2(void)`
  - `void pic2pdf_xnn_set_sme2(int enabled)` — must run before any model load
  - `int pic2pdf_xnn_sme2_active(void)` — 1/0/-1; initializes XNNPACK, so call only after the gate is set
- The project uses a synchronized folder group (`objectVersion = 77`), so **new files under `Pic2PDF/` are picked
  up automatically. Do not edit `project.pbxproj`.** There is **no bridging header**; call C from Swift with
  `@_silgen_name` (this pattern was verified in the research harness):
  ```swift
  @_silgen_name("pic2pdf_cpu_has_sme2") private func c_cpu_has_sme2() -> Int32
  @_silgen_name("pic2pdf_xnn_set_sme2") private func c_xnn_set_sme2(_ enabled: Int32)
  @_silgen_name("pic2pdf_xnn_sme2_active") private func c_xnn_sme2_active() -> Int32
  ```

## 4. Tasks

### T1 [cloud] `Pic2PDF/SME2/SME2Support.swift` — the single source of truth

A small `enum SME2Support` (no UIKit):

- `static let isSupported: Bool` → `c_cpu_has_sme2() == 1`, **unless** the debug override below forces it off.
- Debug override for testing unsupported devices (the user has no pre-A18 iPhone):
  `UserDefaults` key `debugForceNoSME2` **or** launch environment `PIC2PDF_FORCE_NO_SME2=1` → treat as unsupported.
  Only honour the UserDefaults key in `#if DEBUG`; honour the env var always (it only exists when launched from Xcode/devicectl).
- User preference: `UserDefaults` key `sme2Enabled`, **default true** (register the default; don't treat "missing" as false).
- `static var requestedMode: Mode` where `enum Mode: String { case sme2, neon }` →
  `.sme2` iff `isSupported && sme2Enabled`.
- `static func configureBeforeModelLoad()`: calls `c_xnn_set_sme2(requestedMode == .sme2 ? 1 : 0)` exactly once
  (guard with a static flag), and records `requestedModeAtLaunch`.
- `static private(set) var activeMode: Mode?` → set after the first model load from `c_xnn_sme2_active()`
  (1 → `.sme2`, 0 → `.neon`, -1 → leave nil). This is what the UI shows.
- `static var needsRestart: Bool` → `sme2Enabled`-derived mode ≠ `requestedModeAtLaunch`.

### T2 [cloud] Call it at the right time

- XNNPACK initializes inside `LlmInference(options:)`. `OnDeviceLLMService.shared` starts loading in its `init`,
  and `ContentView` touches `OnDeviceLLMService.shared` on first render.
- Call `SME2Support.configureBeforeModelLoad()` in `Pic2PDFApp.init()` (add an `init()` to the `App` struct).
  That runs before any view body. Also call it defensively at the top of `OnDeviceModel.init` (the static
  guard makes the second call a no-op).
- After `inference = try LlmInference(options: options)` in `OnDeviceModel.init`, call
  `SME2Support.recordActiveModeAfterLoad()` (reads `c_xnn_sme2_active()`).
- Publish it: add `@Published var accelerationMode: SME2Support.Mode?` to `OnDeviceLLMService`, set on the main
  actor after init succeeds.

### T3 [cloud] Weight-cache invalidation (prevents the crash for existing users)

In `OnDeviceModel.init`, **before** constructing `LlmInference`:

- `let cacheURL = URL(fileURLWithPath: modelCopyPath.path + ".xnnpack_cache")`
- Keep a marker in `UserDefaults`: key `xnnCacheBuiltMode_<fileName>` = `"sme2"` / `"neon"`.
- If the cache file exists **and** (the marker is missing **or** ≠ `SME2Support.requestedModeAtLaunch.rawValue`):
  delete the cache file. Missing marker = built by an older app version = NEON, but delete anyway to be safe.
- After `LlmInference` succeeds, write the marker = the requested mode.
- Log with `NSLog` when you delete it, including the size.
- Do not delete the `.task` file or the extracted vision files.

### T4 [cloud] Indicator (decision: main screen + Stats)

- Main screen: a small capsule badge **"SME2"** (accent color) or **"NEON"** (secondary) near the top of
  `MainGenerationView`, shown only once the model is initialized. There is an existing `struct Badge` in
  `ContentView.swift` (line ~398) — reuse its style. Use `llmService.accelerationMode`.
- Stats tab (`StatsView.swift`, `InfoSection(title: "Model & System")`): add rows
  "Acceleration: SME2 / NEON", "CPU supports SME2: Yes / No".

### T5 [cloud] Settings toggle

In `SettingsView.swift`, in the existing Performance section:

- `Toggle("Arm SME2 acceleration", isOn: $sme2Enabled)` with `@AppStorage("sme2Enabled") var sme2Enabled = true`.
- Disabled when `!SME2Support.isSupported`, with footer text "Not supported on this device (needs A18 / M4 or newer)."
- When `SME2Support.needsRestart`, show "Restart Img2LaTeX to apply." Do **not** try to reload the model in-process;
  the XNNPACK gate is locked after first init.
- `#if DEBUG`: a "Simulate device without SME2" toggle bound to `debugForceNoSME2`.

### T6 [cloud] Benchmark screen (decision: in Stats tab, results stay on device)

New `Pic2PDF/SME2/BenchmarkView.swift` + a small runner, reachable from a "Run SME2 benchmark" row in `StatsView`.

- Fixed input so runs are comparable: bundle one sample image (see T8) and use the **same prompt** as
  `createLaTeXGenerationPrompt(additionalPrompt: nil)`.
- Fixed settings: `topk = 1`, `topp = 1`, `temperature = 1`, `randomSeed = 0`, vision on. Output length varies
  with content, so report per-token rates, not only totals.
- Run 1 warm-up + 3 measured generations on the already-loaded model (reuse `OnDeviceLLMService`'s current model;
  expose a method there rather than creating a second `LlmInference`, which would double memory).
- Measure per run (same definitions as the research): time to first token (generate call → first non-empty chunk),
  decode tok/s = (outputTokens − 1) / (end − firstChunk) using `session.sizeInTokens`, total time, peak RSS
  (`ProcessMetrics.currentResidentMemoryMB()` sampled), thermal state.
- Store the median result per mode as JSON in `UserDefaults` key `benchmark_<mode>` with device model and date.
- UI: shows the current mode's result. If only one mode has a result, show
  "Switch SME2 off in Settings, restart, and run again to compare." If both exist, show a side-by-side table
  with % difference. Disable the button if the model isn't loaded or a generation is running.
- No network calls.

### T7 [cloud] Quality fixes (decided: yes)

- Generation (`generateLaTeX`) uses **greedy decoding**: `topK = 1` (temperature/topP then don't matter).
  Transcription should be deterministic. Keep the user's sampling settings for **refine** only, and update the
  Settings section footer to say sampling settings apply to refinement.
- Image downscale cap: `maxDimension` **768** (the vision encoder's largest native size) instead of 1536 / 1024.
  Keep Performance Mode meaningful: 512 in performance mode, 768 otherwise.
- Do not change the prompt in this release.

### T8 [cloud] Sample image for the benchmark

- Add a real-looking handwritten-math image to `Pic2PDF/Assets.xcassets` or as a bundle resource under
  `Pic2PDF/SME2/`. The synthetic image used in September was garbled (Flux-generated) and is **not** suitable for
  judging quality. If no real photo is available in the cloud session, add a placeholder and list it in §5 for the user.

### T9 [cloud] README

- Remove/replace claims that SME2 is used "automatically" on iPhone 16 / M4 (README lines ~3, 8, 26, 44, 51, 59,
  96, 521). New wording: SME2 is enabled by default on A18/M4-class devices via XNNPACK/KleidiAI, with a Settings
  toggle and an in-app benchmark; older devices use NEON.
- Add a short "SME2 results" section with the measured numbers from §2 (iPhone 16 Pro Max, Gemma 3n E2B).
- Do not add screenshots you can't produce.

### T10 [cloud] Keep it reviewable

- Commit per task with clear messages. Do not reformat unrelated code.
- End each commit message with the attribution line required by the session.
- Do **not** merge to `main` and do **not** push tags. Push the `sme2-default` branch only.

## 5. Left for the Mac session [mac]

1. `pod install`, fix any compile errors from the cloud-written Swift (expected to be few).
2. Re-sign: Xcode → Settings → Accounts is currently signed out ("No Accounts"); sign in so automatic
   signing works for team `2BBZB7V6G7`.
3. On the iPhone 16 Pro Max:
   - Fresh install → badge shows **SME2**, generate works.
   - **Update test:** install the current App Store version first, run it once (builds a NEON cache), then install
     this build over it → must **not** crash; log should show the cache being deleted; badge **SME2**.
   - Toggle off → "restart to apply" → relaunch → badge **NEON**, cache rebuilt, no crash. Toggle back on, same.
   - `PIC2PDF_FORCE_NO_SME2=1` launch → toggle disabled, badge NEON.
   - Benchmark in both modes → comparison shows TTFT improvement in the same direction as §2.
   - 10 real handwritten photos → check quality with greedy + 768.
4. Archive and submit to App Store Connect (user's account).

## 6. Out of scope for this release

- LiteRT-LM / YNNPACK / Gemma 4 migration (planned "part two" after the blog).
- The duplicate 3 GB model copy into Application Support in `OnDeviceModel.init` (worth fixing later; changes
  storage behaviour for existing users, so not in this release).
- The research benchmark harness (`Pic2PDF/Bench/`) stays on the research branch; do not bring it here.
