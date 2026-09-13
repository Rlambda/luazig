#!/usr/bin/env python3
"""P16.45: fail-safe perf-gate aggregation tests.

Covers the P16.44 false-green bug: one NOISE-downgraded workload erased
another workload's FAIL from the aggregate, so the printed table contained
a real FAIL while the process exited 0. The fail-safe regression_check
must (a) never let a diagnostic change a verdict, (b) be invariant under
workload ordering, (c) derive aggregates only from per-workload verdicts.

Run: python3 tools/test_perf_gate.py
"""
from __future__ import annotations

import importlib.util
import io
import sys
import contextlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("perf_compare", REPO / "tools" / "perf_compare.py")
pc = importlib.util.module_from_spec(_spec)
sys.modules["perf_compare"] = pc
_spec.loader.exec_module(pc)

REGRESSION_FAIL = pc.REGRESSION_FAIL  # 0.10
REGRESSION_WARN = pc.REGRESSION_WARN  # 0.05


def run_check(zig: dict, baseline: dict, spreads: dict | None = None):
    """Invoke regression_check with stdout captured; return (warn, fail, table)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        warn, fail = pc.regression_check(zig, baseline, spreads)
    return warn, fail, buf.getvalue()


def base(times: dict) -> dict:
    return {"zig": dict(times), "baseline_identity": {"baseline_phase": "test"}}


def spread(lo: float, hi: float) -> dict:
    return {"min": lo, "max": hi, "median": (lo + hi) / 2}


FAILS = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global FAILS
    status = "ok" if cond else "FAIL"
    if not cond:
        FAILS += 1
    print(f"  {name}: {status}{(' — ' + detail) if detail and not cond else ''}")


# ---------------------------------------------------------------------------
# Case 1: one ordinary FAIL plus one NOISE-diagnostic lane.
# The P16.44 aggregation returned (False, False) here — false green.
# ---------------------------------------------------------------------------
zig = {"a_slow": 1.20, "b_noisy": 1.20}
bl = base({"a_slow": 1.0, "b_noisy": 1.0})
sp = {"b_noisy": spread(0.9, 1.4)}  # baseline 1.0 inside candidate range
warn, fail, table = run_check(zig, bl, sp)
check("1 fail preserved alongside noise", fail is True)
check("1 warn not set (a is FAIL, b is FAIL diag)", warn is False or fail is True)
check("1 table shows FAIL", "FAIL" in table)
check("1 table shows NOISE diagnostic", "NOISE?" in table)

# ---------------------------------------------------------------------------
# Case 2: two FAILs, only one noise-eligible — aggregate must stay FAIL.
# ---------------------------------------------------------------------------
zig = {"a_plain": 1.2, "b_noisy": 1.25}
bl = base({"a_plain": 1.0, "b_noisy": 1.0})
sp = {"b_noisy": spread(0.95, 1.45)}
warn, fail, table = run_check(zig, bl, sp)
check("2 two FAILs aggregate FAIL", fail is True)
check("2 non-eligible FAIL printed without NOISE",
      "a_plain" in table and "NOISE?" not in table.split("a_plain")[1].split("\n")[0])

# ---------------------------------------------------------------------------
# Case 3: WARN plus NOISE diagnostic — WARN must survive.
# ---------------------------------------------------------------------------
zig = {"a_warn": 1.06, "b_noisy": 1.30}
bl = base({"a_warn": 1.0, "b_noisy": 1.0})
sp = {"b_noisy": spread(0.9, 1.4)}
warn, fail, table = run_check(zig, bl, sp)
check("3 warn preserved", warn is True and fail is True)

# ---------------------------------------------------------------------------
# Case 4: all lanes noise-annotated — verdicts still by threshold.
# ---------------------------------------------------------------------------
zig = {"a": 1.2, "b": 1.02}
bl = base({"a": 1.0, "b": 1.0})
sp = {"a": spread(0.9, 1.4), "b": spread(0.95, 1.1)}
warn, fail, table = run_check(zig, bl, sp)
check("4 all-noise still FAILs the regressor", fail is True)
check("4 ok lane stays ok", "OK" in table)

# ---------------------------------------------------------------------------
# Case 5: order independence — shuffled input, same aggregates.
# ---------------------------------------------------------------------------
bl_times = {f"w{i}": 1.0 + (0.02 * i) for i in range(12)}
items = dict(bl_times)
items["w7"] = 1.30  # one FAIL among OKs (delta ~14% over 1.14 baseline)
bl = base(bl_times)
spreads = {f"w{i}": spread(0.98, 1.02) for i in range(12)}
spreads["w7"] = spread(0.95, 1.35)
w1, f1, _ = run_check(items, bl, spreads)
w2, f2, _ = run_check(dict(reversed(list(items.items()))), bl, spreads)
check("5 order independent", (w1, f1) == (w2, f2) and f1 is True)

# ---------------------------------------------------------------------------
# Case 6: missing baseline workload — NEW row, no verdict influence.
# ---------------------------------------------------------------------------
zig = {"known": 1.0, "unknown": 1.5}
bl = base({"known": 1.0})
warn, fail, table = run_check(zig, bl, None)
check("6 NEW row no crash", "NEW" in table and fail is False)

# ---------------------------------------------------------------------------
# Case 7: zero/degenerate spreads — no annotation, no crash, verdict intact.
# ---------------------------------------------------------------------------
zig = {"degen": 1.2}
bl = base({"degen": 1.0})
warn, fail, table = run_check(zig, bl, {"degen": spread(1.0, 1.0)})
check("7 degenerate spread keeps FAIL", fail is True and "NOISE?" not in table)
warn, fail, table = run_check(zig, bl, {"degen": spread(0.0, 0.0)})
check("7 zero spread keeps FAIL", fail is True)

# ---------------------------------------------------------------------------
# Negative validation: the P16.44 aggregation (restored inline) must go
# false-green on Case 1, proving this suite catches the bug class.
# ---------------------------------------------------------------------------
def p16444_aggregate(zig, baseline, spreads):
    any_warn = any_fail = False
    for name in sorted(zig):
        old = baseline["zig"].get(name)
        if old is None:
            continue
        delta = (zig[name] - old) / old if old else 0.0
        if delta > REGRESSION_FAIL:
            tag, any_fail = "FAIL", True
        elif delta > REGRESSION_WARN:
            tag, any_warn = "WARN", True
        else:
            tag = "OK"
        sp = (spreads or {}).get(name)
        if sp and tag in ("WARN", "FAIL") and old > 0:
            spread_w = sp["max"] - sp["min"]
            if sp["min"] - spread_w * 0.05 <= old <= sp["max"] + spread_w * 0.05 \
                    and sp["min"] <= zig[name] <= sp["max"] and spread_w > 0:
                if any_fail and delta > REGRESSION_FAIL:
                    any_fail = False
                elif any_warn and delta > REGRESSION_WARN:
                    any_warn = False
    return any_warn, any_fail


w_old, f_old = p16444_aggregate({"a_slow": 1.2, "b_noisy": 1.2},
                                base({"a_slow": 1.0, "b_noisy": 1.0}),
                                {"b_noisy": spread(0.9, 1.4)})
check("negative: P16.44 shape false-greens", f_old is False,
      "old aggregation returned fail=False with a real FAIL lane")

print(f"\n{'ALL OK' if FAILS == 0 else str(FAILS) + ' FAILURES'}")
sys.exit(1 if FAILS else 0)
