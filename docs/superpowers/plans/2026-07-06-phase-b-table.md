# Phase B: PUC-faithful Table — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or executing-plans. Checkbox (`- [ ]`) tracking.

**Goal:** Replace the 4-map `Table` (array + fields + int_keys + ptr_keys) with PUC's unified array-part + hash-part (Node[] with Brent's-variation chaining), killing the `next_hint_*` machinery and tombstones. Target: `nextvar.lua` ≥ 10× faster.

**Architecture (from brainstorm, PUC `ltable.c:13-24`):**
- `Node = { key: Value, value: Value, next: ?*Node }`; collisions resolved by separate chaining with Brent's variation (a key not in its main position collides with a key that IS).
- Array part: keys 1..alimit. Hash part: everything else (large ints, strings, objects, bools).
- `next()`: linear scan array (asc) then hash (memory order) — matches `luaH_next`.
- `#` (length): border search (PUC `unbound_search`).
- No tombstones (deletion = unlink).

**Branch:** `phase-b-table-unification` (from `phase-a-string-interning`).

---

## Sequencing

Build-and-test the new hash machinery in isolation FIRST (TDD, no parity risk), then wire it in (B1-style: route sites through the new Table API + swap representation together, since the new API is the final one).

- [x] **B-core:** `src/lua/ltable.zig` — `Node`, hash part, `lookup`/`insert` (Brent)/`delete`/`nextLiveIndex`/`rehash`. TDD each. *(done, all green)*
- [x] **B-wire-1/2/3:** New `Table` internals (array slice + `[]ltable.Node` hash); `rawGet`/`rawSet`/`rawNext`/`rawLen`/GC traversal; routed ~529 sites; deleted `next_hint_*`, `hash_tombstones`, `PtrKey`, `nextFrom*`/`nextFirstLive*`, the 3 maps. *(done; 4 parity fixes during integration: next() deadok, GC weak-key/value marking, debug.getinfo activelines fallback, getFieldOpt pub)*
- [x] **B-verify (parity):** all 10 canaries green (nextvar/sort/tpack/locals/calls/strings/db/gc/pm/literals). Full safe matrix not re-run to completion (memory-heavy without the limits wrapper) but canaries + targeted parity hold.
- [ ] **B-verify (perf) — NOT MET, hypothesis revised:** `nextvar.lua` at Debug barely moved (33s→29.5s). Diagnosis: Debug is dominated by assert/overflow-check overhead in hot loops; **ReleaseFast nextvar is 1.48s (~23× ref)**, so the real remaining gap is **IR-VM interpreter speed**, not the table structure. The "≥10× at Debug" target was a misconceived metric. Next perf investigation: profile the IR-VM dispatch loop (separate effort).

## Key references (PUC, vendored)
- `lua-5.5.0/src/ltable.c:13-24` — chaining + Brent's variation invariant.
- `ltable.c:829-887` — `getfreepos`/`insertkey` (Brent evict).
- `ltable.c:637-746` — `reinserthash`/`luaH_resize`/`computesizes`.
- `ltable.c:929-942` — `getintfromhash` (chain walk).
- `ltable.c:291-303` — `getgeneric` deadok (next() over deleted keys).
- `lvm.c:391-405` — `l_strcmp` (ordering, unchanged).

## Note on `computesizes`
The array-boundary optimization (PUC `computesizes`/`numusearray`/`numusehash`) is **not** ported. `rawSet` uses a simple "append at array.len+1, pull following int keys from hash" densify policy. Correct (parity holds); PUC's optimal array sizing is a future optimization if `#`/unpack hot paths need it.
