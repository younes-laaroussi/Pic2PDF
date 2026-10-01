# Arm SME2 on iPhone: what is actually switched on, and what it buys

Everything here was measured on one iPhone 16 Pro Max (A18 Pro, iOS 27 beta) running Gemma 3n E2B INT4 through MediaPipe Tasks GenAI 0.10.24. The headline result is in the [top-level README](../README.md#arm-sme2); this folder holds the evidence.

## Findings

1. **SME2 kernels are compiled into the shipped MediaPipe binary** (307 `sme2` symbols) **but never used.** XNNPACK decides with a flag, `xnn_enable_arm_sme2_default`, that is 0 and never set. The phone itself reports SME2 (`hw.optional.arm.FEAT_SME2 = 1`, 512-bit vectors). Disassembly: [`evidence/`](evidence/).
2. **Setting the flag before XNNPACK first initializes turns SME2 on.** `xnn_internal_set_arm_sme2(1)` does it; afterwards it has no effect. That is the whole switch (`Pic2PDF/SME2/xnn_sme2.c`).
3. **With SME2 on, the float and INT8 matrix multiplies move to KleidiAI `sme2_mopa` kernels. The INT4 layers (`qs8_qc4w`) stay on NEON.** Time profiles: [`data/profiles/`](data/profiles/).
4. **Result (18 vs 18 runs):** time to first token −41 %, decode +9.7 %, whole call −23 %, memory +1.5 %. Output text is identical on every run within each setting, and the two settings give different text for the same image, so SME2 changes the arithmetic slightly; both outputs are valid.
5. **The XNNPACK weight cache is not tagged by instruction set**, so switching modes against an old cache aborts the process. The app handles this; see the top-level README.
6. **Newer upstream code adds SME paths for INT4** (XNNPACK `76fa737a0b`, prefill only; `d89ef6669a` for Linux arm64 in LiteRT-LM). Neither is in the 0.10.24 binary, so decode speed on iPhone should improve when MediaPipe picks them up. That is an expectation, not a measurement.

## Contents

| Path | What |
|---|---|
| [`methodology.md`](methodology.md) | How the runs were made, what was controlled, what was not |
| `data/fixed64/` | Raw per-run records (`raw/*.jsonl`), flattened `runs.csv`, `init.csv`, `stats.md`, `stats.json` |
| `data/charts/` | Charts generated from the data |
| `data/profiles/` | Time Profiler summaries for NEON and SME2 |
| `data/smoke/` | Short sanity runs |
| `evidence/` | Disassembly of the XNNPACK hardware-config and cpuinfo code that gates SME2 |
| `scripts/` | `analyze.py` (stats + charts), `run_ab.sh` (alternating runs), trace and symbol helpers |
| `harness/` | The headless benchmark runner and its input image, see [`harness/README.md`](harness/README.md) |
| `environment.json`, `model.json` | Device, OS, toolchain, model file hash and size |

## Reproduce the statistics

```bash
python3 scripts/analyze.py data/fixed64/raw data/fixed64   # rewrites stats.md and runs.csv
```

Needs Python 3 with `matplotlib` for the charts. Re-running on the included raw files gives byte-identical `stats.md`.

## Honest limits

- One phone, one model, one image, 64 output tokens.
- Most runs began with the phone in the "serious" thermal state. Alternating arms protects the comparison but not the absolute numbers.
- Time to first token includes image encoding, part of which runs on the GPU and is unaffected by SME2.
- These are not Arm-published numbers and the project is not endorsed by Arm.
