# Methodology

## Question
Does enabling the SME2 execution path that already ships inside MediaPipe Tasks GenAI 0.10.24
change the real app's inference performance on an iPhone 16 Pro Max (A18 Pro), for the app's
real model (Gemma 3n E2B INT4) and real pipeline (image → LaTeX)?

## Approach: HYPOTHESIS → TEST → EVIDENCE → CONCLUSION

| # | Hypothesis | Test | Evidence | Conclusion |
|---|---|---|---|---|
| H1 | The shipped runtime contains SME2 kernels | `nm` over the static archive and over the linked app binary | `nm` over `MediaPipeTasksGenAIC` (ios-arm64) and the linked app: 307 `sme2` symbols in the archive; in the app: `xnn_qp8_f32_qc4w_gemm_minmax_ukernel_{1x128c4,32x128c4}__neonsme2`, `kai_run_matmul_clamp_f32_qai8dxp1x4_qsi4cxp4vlx4_1x4vl_sme2_sdot`, `…qai8dxp1vlx8_qsi4cxp4vlx8_1vlx4vl_sme2_mopa`, `…f32p2vlx1biasf32_sme2_mopa`, `…qsi8cxp2vlx4sb_1x16vl_sme2_dot`, … | PRESENT IN BINARY |
| H2 | SME2 is gated off at runtime | Disassemble `hardware-config.o`, `set_arm_sme2.o` | `evidence/xnn_hardware-config.dis`: `use_arm_sme2 = (xnn_enable_arm_sme2_default != 0) && cpuinfo_isa.sme2`; the default lives in `__common` (zero-initialised); `nm -o` shows **no object references `xnn_internal_set_arm_sme2`** | Gate is OFF and nothing in the runtime turns it on |
| H3 | Gate off-by-default is deliberate upstream | `gh api` on google/XNNPACK history | commits `8a396b78d1` (2025‑06‑12 "Disable ARM SME2 support by default"), `e020076abf` ("disabled by default until we can test it reliably and continuously"), `001e5b57d2` (2025‑06‑23 removed the setter) | Yes; MediaPipe 0.10.24 snapshotted XNNPACK inside that 11‑day window |
| H4 | A18 Pro supports SME2 | `sysctlbyname` from inside the app process (same keys cpuinfo reads, verified in `evidence/cpuinfo_arm_mach_init.dis`) | `FEAT_SME=1 FEAT_SME2=1 SME_I8I32=1 SME_F32F32=1 sme_max_svl_b=64`; XNNPACK's own config readback: `use_arm_sme=1` in both configs | Supported; SVL = 512 bit |
| H5 | Flipping the gate makes XNNPACK select SME2 | Read back `xnn_hardware_config` after init (`bench_xnn_hw_flags`) | `arch_flags 0x4ffc → 0xcffc`, `use_arm_sme2 0 → 1` (`xnn_hw` record in every log) | Yes |
| H6 | SME2 kernels actually execute | Instruments Time Profiler on device, both configs, same workload | `data/profiles/sme2_timeprofile_summary.txt`: `kai_run_matmul_clamp_f32_qai8dxp1x4_qsi4cxp4vlx4_1x4vl_sme2_sdot` 4.6 %, `…f32p2vlx1biasf32_sme2_mopa` 10.4 %, `…qsi8cxp2vlx4sb_1x16vl_sme2_dot` 5.4 %, `…2vlx2vl_sme2_mopa` 0.9 %, `rhs_pack_nxk_f32…_sme` 16.8 %; none of these in the baseline profile | EXECUTED AT RUNTIME |
| H7 | Baseline INT4 matmuls use NEON dotprod / I8MM | Same profiles; `.L` asm labels resolved to enclosing symbols (`scripts/resolve_labels.py`) | `xnn_qs8_qc4w_gemm_minmax_fp32_ukernel_{1x16c4,5x16c4}__asm_aarch64_neondot_ld128_2` = 27 % of baseline CPU time; `xnn_qs8_qc8w_gemm…__neoni8mm` 7.5 %; `kai_…neon_dotprod` 4.9 %, `kai_…neon_i8mm` 0.6 % | Baseline INT4 GEMM/GEMV = NEON **dotprod** asm kernels; I8MM used for INT8 FCs |
| H8 | The biggest INT4 GEMM stays on NEON even with SME2 | Same label resolution on the SME2 profile | `qs8_qc4w …neondot` kernels = 33 % of the SME2 profile; `xnn_qp8_f32_qc4w…32x128c4__neonsme2` never sampled | XNNPACK has no SME2 kernel for the static‑quant `qs8_qc4w` config the model's INT4 FCs use |

## Workload (identical for A and B)
- Model: `gemma-3n-E2B-it-int4.task` (see `model.json`), vision encoder/adapter extracted exactly as the app does.
- Image: `harness/bench_math.png`, 1152×896 RGB PNG, SHA‑256 `f475c36b…d5fc` (a synthetic photo of handwritten math; the app's own `downscaleCGImageAccelerate` does nothing to it because it is < 1536 px, so it is fed unchanged, as the app would).
- Prompt: the app's `createLaTeXGenerationPrompt` text verbatim (152 tokens by the runtime tokenizer). Prefill = 152 prompt + 256 image + 8 template tokens = 416 tokens (established by the context-cap experiment: `maxTokens=480` yields exactly 64 output tokens).
- Sampling: `topk=1, topp=1.0, temperature=1.0, randomSeed=0` (greedy) so a fixed input yields a deterministic output; any divergence between A and B is then attributable to kernel numerics.
- Output length: **fixed‑64 workload** uses `maxTokens=480` so both configs generate exactly 64 tokens (context cap), which makes decode time and end‑to‑end directly comparable. The natural‑EOS workload (`maxTokens=1024`) is reported separately because greedy outputs diverge between kernel paths (128 vs 99 tokens in smoke runs).
- One release binary (`app_binary_sha256` in `environment.json`) for both configs; the config is chosen per process by `BENCH_SME2`.

## Measurement
- Harness: `harness/BenchmarkRunner.swift` (headless, no UI, does not touch `OnDeviceLLMService`).
- Timers: `Date()` around each API call. `ttft` = `generateResponseAsync()` call → first non‑empty chunk (verified per‑token streaming: 65 chunks for 64 tokens). `decode` = first chunk → stream end. `gen` = call → end. `e2e` = session create → end (includes the ~3 s per‑generation session creation the app also pays).
- Tokens: `session.sizeInTokens()` (runtime SentencePiece tokenizer), never chars/4.
- Memory: `mach_task_basic_info.resident_size` (RSS), `task_vm_info.phys_footprint` and `ledger_phys_footprint_peak`; footprint sampled every 100 ms during generation for the in‑run peak.
- Thermal: `ProcessInfo.thermalState` before/after each run. No "device temperature" is reported (the app's `deviceTemperature` is a simulated value and was excluded).
- Battery/power: phone on USB power throughout (`batteryState=2`), Low Power Mode off.
- Kernel execution: `xcrun xctrace record --template 'Time Profiler'` on device, 70 s window covering init + 2 fixed‑64 runs per config; exported with `xctrace export` and aggregated by `scripts/analyze_trace.py`.

## Protocol
- Interleaved processes: baseline, SME2, baseline, SME2, … (`scripts/run_ab.sh`). Each process = 1 warm‑up iteration (excluded) + 3 measured iterations, with in‑process sleeps and an inter‑process cool‑down. Process‑level metrics (init time, RSS after load) get one sample per process.
- Both configurations use a **warm** XNNPACK weight cache (built once per config in the smoke runs) so init numbers exclude weight packing. Cold (cache‑building) init was 11.0 s (baseline) / 11.0 s (SME2) in the smoke runs.
- Statistics: N, median, mean, SD, p10/p90, Δ of medians. Raw per‑run JSON is in `data/fixed64/raw/*.jsonl` and flattened in `data/fixed64/runs.csv`; `scripts/analyze.py` regenerates `stats.md` and the charts from the raw files.

## Limitations
- Vision encoding and LLM prefill cannot be separated with the public MediaPipe API (`addImage` returns in ~10 ms; the encoder runs lazily inside the generate call). TTFT therefore = vision encode + 416‑token prefill + first decode step. The profiler shows the vision encoder is a small fraction (≈0.1 s of main‑thread samples per run).
- Worker‑thread samples (~72 %) carry no calling context in the export, so per‑graph attribution uses the ~28 % of samples taken on the calling thread.
- **Thermal state.** The phone was warm for most of the session: 12 of 18 baseline runs and 14 of 18 SME2 runs started in the `serious` thermal state (the rest `nominal`/`fair`), so absolute speeds are lower than a cool phone would give (decode fell from about 11.5 to about 8.6 tok/s over the session in both arms). Alternating the arms keeps this from favouring either, but the SME2 arm ran slightly hotter on average, so the decode gain is not inflated by temperature. Thermal state per run is in `data/fixed64/runs.csv`.
- **N.** 18 measured runs per arm from 6 alternating processes each. One extra baseline process that ran before the cool-down interval was lengthened (`fixed64_p1_sme2-0`) is kept in `data/fixed64/raw/` but excluded from the statistics (including it changes every median by under 1 %).
- iOS 27.0 is a beta build; Xcode 27.0.
- The E4B model was not benchmarked (time).
- Only one Arm device was available (plus the M4 host, which also reports SME2 but was not used for app measurements).
