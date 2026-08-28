# tools/perf/ — performance artifacts

## Versioned snapshot (reproducible, committed)

These three files are the **versioned perf snapshot** — the reproducible
artifact that roadmap decisions and STATUS/README claims cite. Produced by
`python3 tools/perf_snapshot.py` (or `perf_compare.py --snapshot-out`).

| File | Contents |
|------|----------|
| `current.json` | Per-workload: zig median time, puc median time, ratio; geomean; runs; date; zig version |
| `current-counters.json` | Per-workload: instructions, cycles, IPC/CPI, branch-misses, cache-misses/references, max RSS (zig + puc) |
| `current-profile-index.json` | Top-N symbols (by cycles%) for 8 hotspot workloads: lua_calls, hash_access, field_access, coroutine_yield, string_concat, string_loop, metamethod_add, temp_table_alloc |

To regenerate:
```sh
python3 tools/perf_snapshot.py                    # timing 5, counters 2
python3 tools/perf_snapshot.py --regenerate-docs  # also update README + STATUS
```

## Regression baseline (separate purpose)

| File | Purpose |
|------|---------|
| `baseline-p15.37.json` | Regression gate baseline — `perf_compare.py` compares current zig times vs this and WARNs/FAILs at +5%/+10%. NOT a snapshot; updated only via `--update-baseline`. |
| `core_baseline.json` | End-to-end upstream-suite timing baseline for `perf_core_snapshot.py` / `perf_guard_core.py`. |

The snapshot and the baseline serve **different purposes** and must not be
merged: the baseline is for detecting regressions between commits; the
snapshot is a versioned record of absolute performance at a point in time.

## Historical artifacts (not maintained)

| Path | Contents |
|------|----------|
| `counters-2026-08-25.json` | One-off counters run (pre-snapshot era) |
| `profiles/2026-08-25/` | One-off perf record/report run (pre-snapshot era) |
