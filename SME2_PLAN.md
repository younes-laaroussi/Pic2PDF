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

- **2026-09-29 cloud session:** T1–T10 below are done. Read §7 (what changed, what is uncertain) before
  building, then work through §5.

## 4. Tasks

### T1 [cloud] `Pic2PDF/SME2/SME2Support.swift` — the single source of truth — **done** (`06d80ba`)

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

### T2 [cloud] Call it at the right time — **done** (`4246dd7`)

- XNNPACK initializes inside `LlmInference(options:)`. `OnDeviceLLMService.shared` starts loading in its `init`,
  and `ContentView` touches `OnDeviceLLMService.shared` on first render.
- Call `SME2Support.configureBeforeModelLoad()` in `Pic2PDFApp.init()` (add an `init()` to the `App` struct).
  That runs before any view body. Also call it defensively at the top of `OnDeviceModel.init` (the static
  guard makes the second call a no-op).
- After `inference = try LlmInference(options: options)` in `OnDeviceModel.init`, call
  `SME2Support.recordActiveModeAfterLoad()` (reads `c_xnn_sme2_active()`).
- Publish it: add `@Published var accelerationMode: SME2Support.Mode?` to `OnDeviceLLMService`, set on the main
  actor after init succeeds.

### T3 [cloud] Weight-cache invalidation (prevents the crash for existing users) — **done** (`e3a07e3`)

In `OnDeviceModel.init`, **before** constructing `LlmInference`:

- `let cacheURL = URL(fileURLWithPath: modelCopyPath.path + ".xnnpack_cache")`
- Keep a marker in `UserDefaults`: key `xnnCacheBuiltMode_<fileName>` = `"sme2"` / `"neon"`.
- If the cache file exists **and** (the marker is missing **or** ≠ `SME2Support.requestedModeAtLaunch.rawValue`):
  delete the cache file. Missing marker = built by an older app version = NEON, but delete anyway to be safe.
- After `LlmInference` succeeds, write the marker = the requested mode.
- Log with `NSLog` when you delete it, including the size.
- Do not delete the `.task` file or the extracted vision files.

### T4 [cloud] Indicator (decision: main screen + Stats) — **done** (`d7c5ce5`)

- Main screen: a small capsule badge **"SME2"** (accent color) or **"NEON"** (secondary) near the top of
  `MainGenerationView`, shown only once the model is initialized. There is an existing `struct Badge` in
  `ContentView.swift` (line ~398) — reuse its style. Use `llmService.accelerationMode`.
- Stats tab (`StatsView.swift`, `InfoSection(title: "Model & System")`): add rows
  "Acceleration: SME2 / NEON", "CPU supports SME2: Yes / No".

### T5 [cloud] Settings toggle — **done** (`daa814c`)

In `SettingsView.swift`, in the existing Performance section:

- `Toggle("Arm SME2 acceleration", isOn: $sme2Enabled)` with `@AppStorage("sme2Enabled") var sme2Enabled = true`.
- Disabled when `!SME2Support.isSupported`, with footer text "Not supported on this device (needs A18 / M4 or newer)."
- When `SME2Support.needsRestart`, show "Restart Img2LaTeX to apply." Do **not** try to reload the model in-process;
  the XNNPACK gate is locked after first init.
- `#if DEBUG`: a "Simulate device without SME2" toggle bound to `debugForceNoSME2`.

### T6 [cloud] Benchmark screen (decision: in Stats tab, results stay on device) — **done** (`4742de2`)

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

### T7 [cloud] Quality fixes (decided: yes) — **done** (`11a2c5b`)

- Generation (`generateLaTeX`) uses **greedy decoding**: `topK = 1` (temperature/topP then don't matter).
  Transcription should be deterministic. Keep the user's sampling settings for **refine** only, and update the
  Settings section footer to say sampling settings apply to refinement.
- Image downscale cap: `maxDimension` **768** (the vision encoder's largest native size) instead of 1536 / 1024.
  Keep Performance Mode meaningful: 512 in performance mode, 768 otherwise.
- Do not change the prompt in this release.

### T8 [cloud] Sample image for the benchmark — **done** (`ba7bd22`)

- Add a real-looking handwritten-math image to `Pic2PDF/Assets.xcassets` or as a bundle resource under
  `Pic2PDF/SME2/`. The synthetic image used in September was garbled (Flux-generated) and is **not** suitable for
  judging quality. If no real photo is available in the cloud session, add a placeholder and list it in §5 for the user.

### T9 [cloud] README — **done** (`4c18d38`)

- Remove/replace claims that SME2 is used "automatically" on iPhone 16 / M4 (README lines ~3, 8, 26, 44, 51, 59,
  96, 521). New wording: SME2 is enabled by default on A18/M4-class devices via XNNPACK/KleidiAI, with a Settings
  toggle and an in-app benchmark; older devices use NEON.
- Add a short "SME2 results" section with the measured numbers from §2 (iPhone 16 Pro Max, Gemma 3n E2B).
- Do not add screenshots you can't produce.

### T10 [cloud] Keep it reviewable — **done** (one commit per task; this file updated in the T10 commit)

- Commit per task with clear messages. Do not reformat unrelated code.
- End each commit message with the attribution line required by the session.
- Do **not** merge to `main` and do **not** push tags. Push the `sme2-default` branch only.

## 5. Left for the Mac session [mac]

1. `pod install`, fix any compile errors from the cloud-written Swift (expected to be few). The likeliest
   spots are listed in §7.3; the SwiftUI files were never compiled.
2. Re-sign: Xcode → Settings → Accounts is currently signed out ("No Accounts"); sign in so automatic
   signing works for team `2BBZB7V6G7`.
3. On the iPhone 16 Pro Max (filter the console on `[SME2]` and `[SME2Benchmark]`):
   - Fresh install → badge (top right of the Generate screen) shows **SME2**, generate works.
     Log: `[SME2] supported=true enabled=true -> requesting SME2`, then `[SME2] XNNPACK is using SME2`.
   - **Update test:** install the current App Store version first, run it once (builds a NEON cache), then install
     this build over it → must **not** crash; log should show
     `[SME2] Deleted XNNPACK weight cache gemma-3n-E2B-it-int4.task.xnnpack_cache (… MB), built for unknown/older app, now sme2`;
     badge **SME2**.
   - After that first SME2 launch, list the app's `Application Support` (Xcode → Devices → Download Container):
     the only `*.xnnpack_cache` should be the model's. If the vision encoder/adapter also have one, it needs the
     same invalidation (see §7.3).
   - Toggle off → orange "Restart Img2Latex to apply." → relaunch → badge **NEON**, log shows the cache deleted
     (`built for sme2, now neon`), no crash. Toggle back on, same in reverse.
   - `PIC2PDF_FORCE_NO_SME2=1` launch (scheme → Run → Arguments → Environment Variables) → toggle disabled and off,
     "Not supported on this device…", Stats "CPU supports SME2: No", badge NEON. The Debug-section toggle
     ("Simulate device without SME2") only exists in Debug builds, and **the Run scheme uses Release**, so use the
     env var, or switch Run to Debug to see it.
   - Benchmark (Analytics → SME2 Benchmark card → Run SME2 benchmark) in both modes → the comparison table shows
     the TTFT improvement in the same direction as §2. While it runs, try Generate: it should refuse with
     "The SME2 benchmark is running…". Expect the UI to pause ~3 s before each run (session creation on the
     main thread, same as a normal generation).
   - **Replace the placeholder benchmark image** `Pic2PDF/SME2/sme2_benchmark_sample.jpg` with a real phone photo
     of handwritten math (same file name; .jpg/.jpeg/.png/.heic all load). Crop/resize to ≤ 768 px on the long side
     and make sure the pixels are upright (no EXIF rotation): `UIImage.cgImage` ignores orientation.
     Old benchmark results are then no longer comparable; they live in UserDefaults `benchmark_sme2` /
     `benchmark_neon` (delete the app or those keys).
   - 10 real handwritten photos → check quality with greedy + 768. Include **portrait camera photos** and
     photo-library HEICs: see the orientation issue in §7.4, which may matter more for quality than either change.
   - Visual pass: badge position on the Generate screen, the new Settings rows, the Stats rows and the
     benchmark screen in light/dark mode.
4. Archive and submit to App Store Connect (user's account).

## 6. Out of scope for this release

- LiteRT-LM / YNNPACK / Gemma 4 migration (planned "part two" after the blog).
- The duplicate 3 GB model copy into Application Support in `OnDeviceModel.init` (worth fixing later; changes
  storage behaviour for existing users, so not in this release).
- The research benchmark harness (`Pic2PDF/Bench/`) stays on the research branch; do not bring it here.

## 7. Cloud session report (2026-09-29)

All ten [cloud] tasks are done, one commit each (T1–T9 hashes are on the headings above; T10 is this update),
on `sme2-default`, not merged and not tagged. `project.pbxproj` was not touched; the new files are under
`Pic2PDF/SME2/` and are picked up by the synchronized group.

### 7.1 What changed, and where it differs from §4

- **T1** `SME2Support.swift` as specified. `isSupported` is read once per process (like XNNPACK's own decision),
  so the debug override also needs a restart. `Mode` has `displayName` ("SME2"/"NEON") and is `Codable` for the
  benchmark store. `recordActiveModeAfterLoad()` logs a warning if XNNPACK's choice differs from the request.
- **T2** As specified (`Pic2PDFApp.init()`, defensive call in `OnDeviceModel.init`, `accelerationMode` published).
- **T3** As specified. One addition: if deleting the cache fails and the cache is (or, with no marker, is assumed
  to be) from the other ISA, the model load throws "Could not reset the model cache…" instead of letting XNNPACK
  SIGABRT. The marker records the *requested* mode, as the plan says.
- **T4** Badge is a right-aligned row at the top of `MainGenerationView` (not a toolbar item, to avoid iOS 26
  glass styling around a colored capsule). `AccelerationBadge` sits next to `Badge` in `ContentView.swift`.
  SME2 = accent color, NEON = `systemGray` (white text stays readable in dark mode; `Color.secondary` would not).
  Stats shows "Unknown" if XNNPACK's config could not be read and "Not loaded" before the model loads.
- **T5** The explanation / "Not supported…" text and the restart notice are captions under the toggle (the section
  already holds Performance Mode, so a section footer would be ambiguous). Text says **"Img2Latex"** (the
  home-screen name, `CFBundleDisplayName`), not "Img2LaTeX". On unsupported devices the toggle shows *off*.
  The Debug toggle lives in its own `#if DEBUG` "Debug" section.
- **T6** Files: `SME2Benchmark.swift` (run/result types, median, JSON store, device id via `uname`, 100 ms memory
  sampler, shared `SME2BenchmarkRunner`) and `BenchmarkView.swift`. The link is its own "SME2 Benchmark" card
  below "Model & System" in Stats. `OnDeviceLLMService.runSME2Benchmark` reuses the loaded model and the
  generation prompt, with topk 1 / topp 1 / temperature 1 / seed 0, vision on, image capped at 768.
  Timing: TTFT = generate call (`addQueryChunk` + `generateResponseAsync`) → first non-empty chunk;
  decode = (tokens − 1) / (end − first chunk) with `sizeInTokens`; total = `addImage` → last chunk; session
  creation (~3 s) excluded. Result per mode = per-metric median of the 3 measured runs, labelled with the mode
  XNNPACK actually chose. Benchmark runs are not added to the generation history/analytics. Additions not in
  the plan: `isGenerating` / `isBenchmarking` on the service, generate/refine refuse to start during a
  benchmark, and `AIChatSession` takes an optional `randomSeed` (unchanged when nil). The UI warns if the two
  stored results used different models.
- **T7** As specified. Generation passes temperature 1 / topP 1 with topK 1 (no effect under greedy; matches the
  benchmark). Performance Mode's sampling tweaks now apply to refinement only; its Settings bullet says so.
- **T8** No real photo was available, so the image is a **placeholder**: legible handwriting-style math
  (factored quadratic, derivative, definite integral, quadratic formula) rendered with the OFL Kalam font on
  ruled paper, 576×768 JPEG. It gives the model something real to transcribe (unlike September's garbled image)
  but it is not a photo; replacing it is in §5.
- **T9** All the "automatic" SME2 claims replaced; new "SME2 Results" section with the §2 numbers; T7's 768/512
  and greedy decoding reflected in the Performance Mode table and pipeline; SME2 files added to Project Structure.

### 7.2 How it was checked without Xcode

- Swift 6.2.4 for Linux, with the project's settings (Swift 5 mode, `-default-isolation MainActor`, the
  approachable-concurrency upcoming features, member import visibility). `SME2Support.swift`,
  `SME2Benchmark.swift` and `OnDeviceLLMService.swift` were type-checked against stub modules for UIKit,
  MediaPipeTasksGenAI, ZIPFoundation, Combine and os: no new diagnostics versus the base branch, also none in
  Swift 6 mode. The stubs only prove my code is consistent with *my assumptions* about those APIs.
- Logic tests (built and run on Linux with a stub C shim): SME2Support decisions (default-on when unset,
  explicit off, env override, DEBUG-only UserDefaults override, one-shot gate, `needsRestart`); cache
  invalidation for every marker/mode combination plus an undeletable cache; the benchmark flow end to end
  against a timed fake MediaPipe stream (warm-up excluded, TTFT/decode/total math, memory sampler running during
  prefill, generation refused mid-benchmark, JSON round trip).
- **Not compiled at all:** `BenchmarkView.swift` and the SwiftUI edits in `ContentView.swift`, `SettingsView.swift`,
  `StatsView.swift`, `Pic2PDFApp.swift`.

### 7.3 Not sure about (check first on the Mac)

1. `LlmInference.Session.Options.randomSeed` is assumed to be `Int` (`AIChatSession`, T6). If it is another type,
   convert in that one place.
2. `@_silgen_name` declarations under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: fine with Swift 6.2.4; if a
   newer compiler complains about isolation, mark the three declarations `nonisolated`.
3. `BenchmarkView`: `Grid`/`GridRow` with `ForEach`, `.gridColumnAlignment` on header cells, and the
   `Text`-returning `changeText(for:)`. Should compile on iOS 17.6, but it is the least-verified file.
4. Simulator builds: `xnn_sme2.c` needs `xnn_internal_set_arm_sme2` / `xnn_init_hardware_config` from the
   simulator slice of `MediaPipeTasksGenAIC`. Only the device build was verified in September.
5. Only `<model>.task.xnnpack_cache` is invalidated (per §2). If other XNNPACK caches show up (§5), extend T3.
6. The cache marker is the requested mode. If the log ever shows `[SME2] WARNING: requested … but XNNPACK is
   using …`, the marker would describe the wrong ISA and should become the active mode.
7. Peak memory in the benchmark is sampled on the main actor; if `addImage` does vision encoding synchronously on
   the main thread, a short peak inside that call can be missed. The numbers should still be close to §2
   (~1.85 GB).

### 7.4 Noticed, not changed (pre-existing, outside this plan)

1. **Image orientation (likely quality issue):** `generateLaTeX` passes `img.cgImage` to the model, and
   `cgImage` ignores `UIImage.imageOrientation`. iPhone portrait photos (camera and most photo-library
   JPEG/HEIC) store sideways pixels plus an orientation flag, so the model probably sees them rotated 90°.
   Quick test: a portrait photo vs. a screenshot of the same photo. Fix if confirmed: redraw upright (e.g.
   `UIGraphicsImageRenderer`) before downscaling.
2. `downscaleCGImageAccelerate` frees `dstBuf.data` in `defer` after `vImageCreateCGImageFromBuffer(…,
   kvImageNoAllocate, …)`, which hands that buffer to the CGImage. Check against the vImage docs whether that
   buffer is still owned by the caller (possible double free).
3. Performance Mode refinement uses `topK ≥ 60`, but `LlmInference.Options.maxTopk` is never set (I believe
   MediaPipe's default is 40). Check that refinement in Performance Mode actually works.
4. README's Podfile snippet still says `target 'Img2Latex'` and lacks the new `post_install` hook.

