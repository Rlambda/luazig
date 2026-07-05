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

- [ ] **B-core:** `src/lua/ltable.zig` — `Node`, `HashPart` (Node[] + lastfree), `lookup`/`insert` (Brent)/`delete`/`nextIndex`/`rehash`. TDD each.
- [ ] **B-wire-1:** New `Table` internals (array slice + `HashPart`); implement `rawGet`/`rawSet`/`rawNext`/`rawLen`/`rawIter` over them.
- [ ] **B-wire-2:** Route the 529 direct map accesses + ~10 `nextFrom*`/`nextFirstLive*` + GC traversal through the new methods. Compile-driven.
- [ ] **B-wire-3:** Delete `next_hint_*` (7 fields), `hash_tombstones`, old 4 maps. `const_strings` removal stays deferred (Phase B doesn't require it — `[]const u8` key path moves to `*LuaString` via the new hash).
- [ ] **B-verify:** parity ≥ 33/34; `nextvar.lua` ≥ 10× faster; perf-guard green; close Phase B1+B2 checkboxes in README.

## Key references (PUC, vendored)
- `lua-5.5.0/src/ltable.c:13-24` — chaining + Brent's variation invariant.
- `ltable.c:829-887` — `getfreepos`/`insertkey` (Brent evict).
- `ltable.c:637-746` — `reinserthash`/`luaH_resize`/`computesizes`.
- `ltable.c:929-942` — `getintfromhash` (chain walk).
- `lvm.c:391-405` — `l_strcmp` (ordering, unchanged).
