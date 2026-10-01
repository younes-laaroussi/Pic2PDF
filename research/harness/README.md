# Benchmark harness

The harness used for the A/B measurements in [`../README.md`](../README.md). It is **not** part of the app target:
it runs the real inference path (`LlmInference` → `Session.addImage` → `generateResponseAsync`) headless, with a
fixed image, a fixed prompt and greedy decoding, and prints one JSON record per line.

| File | Purpose |
| --- | --- |
| `BenchmarkRunner.swift` | The runner. Configured through environment variables (see the header comment). |
| `BenchView.swift` | A minimal SwiftUI host that starts the runner. |
| `bench_xnn.c` | C shim: sets XNNPACK's SME2 gate, reads back its hardware config, and a few probes used while investigating the simulator image bug (direct calls into MediaPipe's C API and Skia's pixel copy). |
| `bench_math.png` | The fixed input image (1152×896, SHA-256 `f475c36b…d5fc`). |

## Using it

1. Check out a copy of the repository, copy these files into `Pic2PDF/Bench/` (the project uses a synchronized
   folder, so Xcode picks them up), and add `bench_math.png` to the app target.
2. In `Pic2PDFApp.swift`, show `BenchView()` instead of the normal UI when `Bench.isEnabled`.
3. Put `gemma-3n-E2B-it-int4.task` in the app's `Documents/Models/` on the device, then launch with
   `devicectl device process launch --console -e '{"PIC2PDF_BENCH":"1","BENCH_SME2":"1",...}'`.
   `scripts/run_ab.sh` drives interleaved baseline/SME2 processes (`DEVICE=<udid> scripts/run_ab.sh ...`).
4. `scripts/analyze.py <raw dir> <out dir>` turns the output into `runs.csv`, `stats.md` and charts.

`BENCH_SME2=1` calls `xnn_internal_set_arm_sme2(1)` before the first XNNPACK initialization. Each configuration uses
its own copy of the model path, because XNNPACK's packed-weight cache is not keyed by instruction set (see
[`../README.md`](../README.md#the-weight-cache-trap)).
