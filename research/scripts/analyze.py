#!/usr/bin/env python3
"""Parse raw benchmark logs (BENCHJSON lines) into CSV, per-config statistics and charts.

Usage: analyze.py <raw_dir> <out_dir> [--label NAME] [--exclude RUN_ID,...]
  raw_dir: directory of *.log (console) or *.jsonl files produced by scripts/run_ab.sh
  out_dir: where runs.csv, init.csv, stats.md, stats.json and charts/*.png are written
"""
import sys, json, glob, os, statistics, argparse, collections
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# Validated categorical palette (dataviz reference instance): slot 1 blue = baseline, slot 2 orange = SME2.
C_BASE, C_SME2 = "#2a78d6", "#eb6834"
TXT, TXT2, GRID = "#0b0b0b", "#52514e", "#e6e5e1"

ap = argparse.ArgumentParser()
ap.add_argument("raw_dir"); ap.add_argument("out_dir"); ap.add_argument("--label", default="")
ap.add_argument("--exclude", default="", help="comma-separated run_id values to drop (e.g. orphan processes)")
args = ap.parse_args()
os.makedirs(os.path.join(args.out_dir, "charts"), exist_ok=True)

records = []
# Raw console logs (lines prefixed "BENCHJSON ") or the cleaned .jsonl files kept in data/ (bare JSON).
for f in sorted(glob.glob(os.path.join(args.raw_dir, "*.log")) + glob.glob(os.path.join(args.raw_dir, "*.jsonl"))):
    for line in open(f, errors="replace"):
        line = line.strip()
        if line.startswith("BENCHJSON "): line = line[len("BENCHJSON "):]
        if not line.startswith("{"): continue
        try: records.append(json.loads(line))
        except json.JSONDecodeError: pass

excl = set(x for x in args.exclude.split(",") if x)
records = [r for r in records if r.get("run_id") not in excl]
env = [r for r in records if r["record"] == "env"]
hw = [r for r in records if r["record"] == "xnn_hw"]
init = pd.DataFrame([r for r in records if r["record"] == "init"])
runs = pd.DataFrame([r for r in records if r["record"] == "run"])
if runs.empty: sys.exit("no run records")

# flatten memory sub-dicts
for col in ["mem_before", "mem_after"]:
    for k in ["rss_mb", "rss_peak_mb", "footprint_mb", "footprint_peak_mb"]:
        runs[f"{col}_{k}"] = runs[col].apply(lambda m: m[k])
for k in ["rss_mb", "rss_peak_mb", "footprint_mb", "footprint_peak_mb"]:
    init[f"after_load_{k}"] = init["mem_after_load"].apply(lambda m: m[k])
envmap = {r["run_id"]: r for r in env}
hwmap = {r["run_id"]: r for r in hw}
init["sme2"] = init["run_id"].map(lambda rid: envmap.get(rid, {}).get("sme2_requested", -1))
init["use_arm_sme2"] = init["run_id"].map(lambda rid: hwmap.get(rid, {}).get("use_arm_sme2", -1))
init["mem_before_load_rss_mb"] = init["run_id"].map(lambda rid: envmap.get(rid, {}).get("mem_before_load", {}).get("rss_mb"))
runs["use_arm_sme2"] = runs["run_id"].map(lambda rid: hwmap.get(rid, {}).get("use_arm_sme2", -1))
runs["e2e_norm_s"] = runs["ttft_s"] + runs["decode_s"]   # generate-call to end, excludes session create

# Sanity: the config the process *asked for* must match what XNNPACK *decided*.
bad = runs[runs["sme2"] != runs["use_arm_sme2"]]
if len(bad): print(f"WARNING: {len(bad)} runs where requested sme2 != XNNPACK use_arm_sme2", file=sys.stderr)

meas = runs[~runs["warmup"]].copy()
runs.drop(columns=["mem_before", "mem_after", "chunk_t_s", "chunk_chars"]).to_csv(os.path.join(args.out_dir, "runs.csv"), index=False)
init.drop(columns=["mem_after_load"]).to_csv(os.path.join(args.out_dir, "init.csv"), index=False)

def q(s, p): return float(s.quantile(p))
def stats(s):
    s = s.dropna()
    return dict(n=int(len(s)), median=float(s.median()), mean=float(s.mean()),
                sd=float(s.std(ddof=1)) if len(s) > 1 else 0.0, p10=q(s, .1), p90=q(s, .9), min=float(s.min()), max=float(s.max()))

METRICS = [  # (column, label, unit, higher_is_better, source df)
    ("ttft_s", "Time to first token", "s", False, "runs"),
    ("decode_tok_s", "Decode throughput", "tok/s", True, "runs"),
    ("decode_s", "Decode time (fixed output)", "s", False, "runs"),
    ("gen_s", "Generate call end-to-end (TTFT + decode)", "s", False, "runs"),
    ("e2e_s", "End-to-end incl. session create", "s", False, "runs"),
    ("session_create_s", "Session creation", "s", False, "runs"),
    ("output_tokens", "Output tokens", "tok", None, "runs"),
    ("mem_after_footprint_mb", "Phys footprint after generation", "MB", False, "runs"),
    ("mem_peak_during_footprint_mb", "Peak phys footprint during generation (100ms sampling)", "MB", False, "runs"),
    ("mem_after_rss_mb", "RSS after generation", "MB", False, "runs"),
    ("llm_init_s", "LlmInference init (warm weight cache)", "s", False, "init"),
    ("session_init_s", "First session creation", "s", False, "init"),
    ("after_load_rss_mb", "RSS after model load", "MB", False, "init"),
    ("after_load_footprint_mb", "Phys footprint after model load", "MB", False, "init"),
    ("after_load_footprint_peak_mb", "Peak phys footprint during load (ledger)", "MB", False, "init"),
]

out = {}
lines = [f"# Results {args.label}", "", f"Measured runs: baseline n={int((meas.sme2==0).sum())}, SME2 n={int((meas.sme2==1).sum())}; "
         f"processes: baseline {int((init.sme2==0).sum())}, SME2 {int((init.sme2==1).sum())}", "",
         "| Metric | Baseline median (mean ± sd) [p10–p90] | SME2 median (mean ± sd) [p10–p90] | Δ median | n |", "|---|---|---|---|---|"]
for col, label, unit, hib, src in METRICS:
    df = meas if src == "runs" else init
    if col not in df: continue
    a, b = df[df.sme2 == 0][col], df[df.sme2 == 1][col]
    if a.empty or b.empty: continue
    sa, sb = stats(a), stats(b)
    d = (sb["median"] - sa["median"]) / sa["median"] * 100 if sa["median"] else float("nan")
    out[col] = dict(label=label, unit=unit, baseline=sa, sme2=sb, delta_median_pct=d)
    fmt = (lambda v: f"{v:.0f}") if unit in ("MB", "tok") else (lambda v: f"{v:.3f}" if unit == "s" else f"{v:.2f}")
    lines.append(f"| {label} ({unit}) | {fmt(sa['median'])} ({fmt(sa['mean'])} ± {fmt(sa['sd'])}) [{fmt(sa['p10'])}–{fmt(sa['p90'])}] | "
                 f"{fmt(sb['median'])} ({fmt(sb['mean'])} ± {fmt(sb['sd'])}) [{fmt(sb['p10'])}–{fmt(sb['p90'])}] | {d:+.1f}% | {sa['n']}/{sb['n']} |")

# Output determinism check
lines += ["", "## Output determinism (greedy decoding)"]
for cfg, name in [(0, "baseline"), (1, "SME2")]:
    c = collections.Counter(meas[meas.sme2 == cfg]["output_sha256_prefix"])
    lines.append(f"- {name}: {len(c)} distinct output(s) over {sum(c.values())} runs: " + ", ".join(f"{k}×{v}" for k, v in c.most_common()))
lines += ["", "## Thermal state at start of each measured run"]
for cfg, name in [(0, "baseline"), (1, "SME2")]:
    c = collections.Counter(meas[meas.sme2 == cfg]["thermal_before"])
    lines.append(f"- {name}: " + ", ".join(f"{k}×{v}" for k, v in c.most_common()))
open(os.path.join(args.out_dir, "stats.md"), "w").write("\n".join(lines) + "\n")
json.dump(out, open(os.path.join(args.out_dir, "stats.json"), "w"), indent=1)
print("\n".join(lines))

# ---------------- charts ----------------
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11, "axes.edgecolor": GRID, "axes.labelcolor": TXT2,
                     "xtick.color": TXT2, "ytick.color": TXT2, "axes.spines.top": False, "axes.spines.right": False,
                     "figure.facecolor": "white", "axes.facecolor": "white"})

def strip_bar(ax, col, title, unit, df, hib):
    a, b = df[df.sme2 == 0][col].dropna(), df[df.sme2 == 1][col].dropna()
    meds = [a.median(), b.median()]
    ax.bar([0, 1], meds, width=0.55, color=[C_BASE, C_SME2], zorder=2)
    for i, (s, c) in enumerate([(a, C_BASE), (b, C_SME2)]):
        jitter = [(i + (k % 7 - 3) * 0.035) for k in range(len(s))]
        ax.scatter(jitter, s, s=18, color="white", edgecolor=c, linewidth=1.2, zorder=4)
        ax.vlines(i, s.quantile(.1), s.quantile(.9), color=TXT, linewidth=1.5, zorder=3)
    d = (meds[1] - meds[0]) / meds[0] * 100
    better = (d > 0) == hib if hib is not None else None
    ax.set_xticks([0, 1]); ax.set_xticklabels(["SME2 off", "SME2 on"], color=TXT)
    for i, m in enumerate(meds):
        ax.text(i, -0.04 * max(a.max(), b.max()), f"{m:.2f}" if unit != "MB" else f"{m:.0f}", ha="center", va="top", fontsize=11, color=TXT, fontweight="bold", transform=ax.transData, clip_on=False)
    ax.set_title(f"{title}   {d:+.0f}%", color=TXT, fontsize=12, loc="left", pad=10)
    ax.set_ylabel(unit); ax.grid(axis="y", color=GRID, zorder=0); ax.set_ylim(0, max(a.max(), b.max()) * 1.15)
    ax.tick_params(axis="x", length=0, pad=22)

fig, axs = plt.subplots(1, 3, figsize=(12, 4.6))
strip_bar(axs[0], "ttft_s", "Time to first token", "s", meas, False)
strip_bar(axs[1], "decode_tok_s", "Decode speed", "tok/s", meas, True)
strip_bar(axs[2], "gen_s", "Image to last token", "s", meas, False)
fig.tight_layout(w_pad=3); fig.savefig(os.path.join(args.out_dir, "charts", "ab_headline.png"), dpi=200); plt.close(fig)

fig, axs = plt.subplots(1, 3, figsize=(12, 4.6))
strip_bar(axs[0], "after_load_footprint_mb", "Memory after load", "MB", init, False)
strip_bar(axs[1], "mem_peak_during_footprint_mb", "Peak memory while generating", "MB", meas, False)
strip_bar(axs[2], "llm_init_s", "Model load", "s", init, False)
fig.tight_layout(w_pad=3); fig.savefig(os.path.join(args.out_dir, "charts", "ab_memory_init.png"), dpi=200); plt.close(fig)

# Time series of interleaved runs (drift / thermal check)
fig, ax = plt.subplots(figsize=(12, 3.8))
m = meas.sort_values("ts_iso").reset_index(drop=True)
for cfg, c, name in [(0, C_BASE, "SME2 off"), (1, C_SME2, "SME2 on")]:
    sel = m[m.sme2 == cfg]
    ax.plot(sel.index, sel["decode_tok_s"], "o-", color=c, label=name, markersize=5, linewidth=1.5)
ax.set_xlabel("run, in time order"); ax.set_ylabel("tok/s")
ax.set_title("Decode speed over the session", loc="left", color=TXT)
ax.grid(axis="y", color=GRID); ax.legend(frameon=False)
fig.tight_layout(); fig.savefig(os.path.join(args.out_dir, "charts", "drift_decode.png"), dpi=180); plt.close(fig)

# Per-token latency profile from chunk timestamps (median across runs per config)
fig, ax = plt.subplots(figsize=(12, 3.8))
for cfg, c, name in [(0, C_BASE, "SME2 off"), (1, C_SME2, "SME2 on")]:
    sel = meas[meas.sme2 == cfg]
    if sel.empty: continue
    L = min(len(t) for t in sel["chunk_t_s"])
    arr = pd.DataFrame([t[:L] for t in sel["chunk_t_s"]])
    med = arr.median()
    ax.plot(range(1, L + 1), med, color=c, label=name, linewidth=2)
    ax.fill_between(range(1, L + 1), arr.quantile(.1), arr.quantile(.9), color=c, alpha=0.15, linewidth=0)
ax.set_xlabel("output token"); ax.set_ylabel("seconds")
ax.set_title("When each token arrived", loc="left", color=TXT)
ax.grid(color=GRID); ax.legend(frameon=False)
fig.tight_layout(); fig.savefig(os.path.join(args.out_dir, "charts", "token_timeline.png"), dpi=180); plt.close(fig)
print("charts written to", os.path.join(args.out_dir, "charts"))
