# Results fixed-64 tokens

Measured runs: baseline n=18, SME2 n=18; processes: baseline 6, SME2 6

| Metric | Baseline median (mean ± sd) [p10–p90] | SME2 median (mean ± sd) [p10–p90] | Δ median | n |
|---|---|---|---|---|
| Time to first token (s) | 5.023 (5.090 ± 0.295) [4.785–5.544] | 2.961 (3.058 ± 0.222) [2.867–3.366] | -41.0% | 18/18 |
| Decode throughput (tok/s) | 10.06 (9.89 ± 0.77) [8.72–10.70] | 11.04 (10.57 ± 1.10) [8.80–11.62] | +9.7% | 18/18 |
| Decode time (fixed output) (s) | 6.260 (6.408 ± 0.510) [5.888–7.228] | 5.705 (6.025 ± 0.682) [5.421–7.156] | -8.9% | 18/18 |
| Generate call end-to-end (TTFT + decode) (s) | 11.281 (11.498 ± 0.769) [10.678–12.756] | 8.665 (9.083 ± 0.819) [8.330–10.213] | -23.2% | 18/18 |
| End-to-end incl. session create (s) | 14.395 (14.586 ± 0.831) [13.679–15.916] | 11.855 (12.170 ± 0.851) [11.287–13.362] | -17.7% | 18/18 |
| Session creation (s) | 3.128 (3.079 ± 0.101) [2.968–3.161] | 3.056 (3.078 ± 0.111) [2.959–3.213] | -2.3% | 18/18 |
| Output tokens (tok) | 64 (64 ± 0) [64–64] | 64 (64 ± 0) [64–64] | +0.0% | 18/18 |
| Phys footprint after generation (MB) | 1524 (1553 ± 66) [1516–1675] | 1553 (1558 ± 12) [1547–1576] | +1.9% | 18/18 |
| Peak phys footprint during generation (100ms sampling) (MB) | 1841 (1814 ± 50) [1739–1860] | 1868 (1853 ± 48) [1771–1895] | +1.5% | 18/18 |
| RSS after generation (MB) | 3016 (2948 ± 254) [2798–3101] | 3069 (3029 ± 111) [2905–3133] | +1.8% | 18/18 |
| LlmInference init (warm weight cache) (s) | 3.097 (3.241 ± 0.343) [3.084–3.541] | 3.081 (3.417 ± 0.799) [3.074–4.095] | -0.5% | 6/6 |
| First session creation (s) | 3.108 (3.095 ± 0.140) [2.936–3.242] | 3.063 (3.079 ± 0.146) [2.950–3.224] | -1.5% | 6/6 |
| RSS after model load (MB) | 3032 (2987 ± 139) [2840–3090] | 2978 (2932 ± 181) [2762–3057] | -1.8% | 6/6 |
| Phys footprint after model load (MB) | 1528 (1528 ± 0) [1528–1528] | 1530 (1530 ± 0) [1530–1530] | +0.1% | 6/6 |
| Peak phys footprint during load (ledger) (MB) | 1737 (1737 ± 0) [1736–1737] | 1738 (1738 ± 0) [1738–1739] | +0.1% | 6/6 |

## Output determinism (greedy decoding)
- baseline: 1 distinct output(s) over 18 runs: cd99132699bb64be×18
- SME2: 1 distinct output(s) over 18 runs: a91018461835a41b×18

## Thermal state at start of each measured run
- baseline: serious×12, nominal×3, fair×3
- SME2: serious×14, fair×4
