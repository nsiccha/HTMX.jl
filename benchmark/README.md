# Performance checks

Use a fresh Julia process after building the package cache:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.precompile(); using HTMX'
julia --startup-file=no --project=. benchmark/performance.jl
```

`FIRST` includes first-use compilation; the adjacent `@time` line reports its
compilation fraction. `WARM` reports median/minimum wall time and median allocated
bytes across 11 samples after two warmups. `ENV` separates package loading from
first calls. Output hashes let two checkouts confirm identical table output.

Run the same script against a baseline checkout with `--project=/path/to/baseline`.
Use the same Julia version, thread settings, and shared depot; prepare both
caches before comparing. Repeat in alternating order on a busy host. Allocations
and counted renderer calls are more stable than elapsed time under shared load.
Array conversion includes 1,000 and 5,000 nodes to expose per-element buffering
and growth. HXML includes both single-class table cells and multiple-class spans;
an iterator change can improve one case while regressing the other.
The hyperscript sizes expose quadratic aggregation; nested headers expose repeated
layout probes. Distinct keyword sets show compilation that a fixed workload cannot
precompile in advance. These measurements are diagnostics, not timing assertions.
