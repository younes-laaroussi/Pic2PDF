#!/bin/zsh
# Interleaved A/B driver: launches the benchmark-mode app on the physical iPhone,
# alternating baseline (SME2 gate off) and experimental (SME2 gate on) processes.
# Each process: BENCH_WARMUP warm-up iterations (excluded) + BENCH_RUNS measured.
# Usage: run_ab.sh <label> <max_tokens> <processes_per_config> <runs_per_process> <outdir> [iter_sleep_s] [proc_cooldown_s]
set -u
LABEL=$1; MAXTOK=$2; PROCS=$3; RUNS=$4; OUT=$5; ISLEEP=${6:-2}; COOL=${7:-10}
DEV=${DEVICE:?set DEVICE to your iPhone UDID}
BUNDLE=com.deepshotinc.Pic2PDF
mkdir -p "$OUT"
for i in $(seq 1 $PROCS); do
  for cfg in 0 1; do
    id="${LABEL}_p${i}_sme2-${cfg}"
    echo "[$(date +%H:%M:%S)] launching $id"
    xcrun devicectl device process launch --console --terminate-existing --device $DEV \
      -e "{\"PIC2PDF_BENCH\":\"1\",\"BENCH_SME2\":\"$cfg\",\"BENCH_RUNS\":\"$RUNS\",\"BENCH_WARMUP\":\"1\",\"BENCH_MAX_TOKENS\":\"$MAXTOK\",\"BENCH_RUN_ID\":\"$id\",\"BENCH_SLEEP\":\"$ISLEEP\"}" \
      $BUNDLE < /dev/null > "$OUT/$id.log" 2>&1
    grep -E "^BENCH (iter|XNNPACK|DONE)|signal|FATAL" "$OUT/$id.log" | sed "s/^/[$id] /"
    sleep $COOL   # cool-down between processes
  done
done
echo "[$(date +%H:%M:%S)] ALL DONE"
