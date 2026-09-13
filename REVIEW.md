---
name: luazig-review
description: >
  Review a luazig phase or repository snapshot against PUC Lua 5.5 with strict
  correctness, architecture, performance, provenance, and regression-gate
  discipline. Use for reviewing phase reports, luazig source codes,
  measured artifacts, proposed next-phase queues, and generating the next
  agent prompt.
---

# luazig-review

## Purpose

Review the **luazig** project as a compiler/runtime/VM implementation, with
special focus on:

- PUC Lua 5.5 semantic parity;
- PUC-faithful runtime architecture;
- Zig code quality and maintainability;
- measured VM performance;
- correctness of profiling and provenance;
- regression-gate integrity;
- choosing the next phase from fresh evidence rather than stale assumptions.

The review is not only a report check. Treat the repository ,
phase report in `report.md`, source code, tests, generated artifacts, and measured binaries as
independent evidence that must agree.

The final output should answer:

1. Is the completed phase acceptable?
2. Which claims are independently supported?
3. Which claims are overstated, stale, incomplete, or false?
4. Did the phase improve architecture or merely add another special case?
5. Are perf conclusions causal and measured correctly?
6. Are all mandatory gates actually satisfied?
7. What is the highest-value next task?
8. What exact prompt should the next implementation agent receive?

---

# Core project principles

## 1. PUC-first, not C-line-by-line

Use PUC Lua 5.5 as the semantic and architectural reference.

Prefer:

- the same ownership boundaries;
- the same lifecycle concepts;
- the same fast/slow-path separation;
- the same reason a condition exists.

Do **not** require mechanical C translation.

Idiomatic Zig is preferred when it preserves PUC concepts more clearly.

A good change should usually make the VM easier to explain in terms of:

- Lua stack / CallInfo;
- saved PC;
- C-call depth / non-yieldable depth;
- coroutine ownership;
- GC reachability;
- continuation ownership;
- hook/trap ownership;
- TBC / close obligations.

## 2. No benchmark-specific or semantic special cases

Reject designs that branch on:

- benchmark name;
- source filename;
- line number;
- test name;
- one specific Lua function name;
- one builtin identity solely to mask a more general semantic rule.

Examples of suspicious patterns:

```text
if builtin == coroutine_yield
if inside_table_sort
if test_name == ...
if script == ...
```

A special builtin classification is acceptable only when it corresponds to a
real semantic class in PUC.

## 3. One owner for mutable runtime state

When reviewing architecture, aggressively look for duplicated ownership.

Bad patterns:

```text
Vm owns a mutable copy while Thread owns another
active vs parked copies requiring synchronization
two writable PC representations
global semantic scratch duplicating CallFrame state
```

Prefer:

```text
Thread owns thread state
Vm selects the active Thread
CallFrame owns call-local state
GC object owns GC lifecycle state
```

Borrowed caches are acceptable only when:

- there is one canonical owner;
- the cache cannot diverge;
- switching/update rules are explicit;
- codegen evidence shows the cache is worthwhile.

## 4. No replay state without necessity

Avoid fields whose purpose is to reconstruct a state transition that should
instead remain represented by the ordinary VM/frame model.

Be suspicious of:

```text
resume_replay_*
saved_special_case_*
pending_magic_*
retry_mode
```

Continuation state should normally belong to:

- CallFrame;
- Thread;
- existing pending call / continuation structures;
- live stack values.

## 5. Correctness before performance

A valid Lua program that:

- crashes;
- loses a continuation;
- produces a wrong error frame;
- yields where PUC rejects;
- rejects where PUC yields;
- closes TBC at the wrong time;
- corrupts GC-visible state;

has higher priority than a perf-only cut.

If a phase report puts such a correctness bug below a micro-optimization,
reorder the next-phase queue.

---

# Expected inputs

Typical review inputs:

- a phase report `report.md`;
- current repository;
- optional prior phase reports;
- optional agent prompt used for the phase;
- optional generated artifacts under `tools/perf/` and `tools/status/`.

Use the repository as primary truth for source structure.

Use generated artifacts as measurement evidence, not as unquestioned truth.

Use the phase report as a claim set to verify.

---

# Toolchain

For luazig verification, use the user-provided **Zig 0.16.0** toolchain.

Do not silently use:

- system Zig of another version;
- stale `tools/zig-bin`;
- an older project-local compiler.

Record:

```text
zig version
compiler path
optional binary hash
```

before making toolchain-dependent conclusions.

---

# Review workflow

## Step 0 — Read project instructions

Read:

```text
AGENTS.md
DESIGN.md
README.md
STATUS.md
```

before evaluating architecture.

Treat `AGENTS.md` as binding project policy.

## Step 1 — Establish source/provenance truth

Determine:

```text
reported input SHA
reported final SHA
reported measured source SHA
actual snapshot source state
```

If `.git` is available:

```bash
git rev-parse HEAD
git status --short
git diff <measured-source>..HEAD -- src/
```

If `.git` is not available:

- use provenance artifacts;
- inspect source directly;
- clearly state what cannot be independently proven.

Do not claim a wrapper commit contains no runtime change unless verified.

## Step 2 — Check formatting immediately

Run:

```bash
zig fmt --check src build.zig tests
```

A phase claiming "fmt-clean" is not accepted as fully clean if this fails.

If the diff is formatting-only:

- classify it as hygiene, not runtime regression;
- still report the gate claim as inaccurate.

## Step 3 — Verify the mandatory gates

At minimum review evidence for:

```text
Debug unit
ReleaseFast unit
smoke
matrix --testc
c_api + diff
api580
TBC suites
hook-related lanes
fmt
```

Expected historical matrix shape:

```text
zig_fail = 0
big.lua = both_fail only
```

Known documented divergences must remain honestly classified.

Do not accept `_soft`, `_port`, output normalization, or skipped diff lanes
presented as green.

If a local execution times out without compiler/test diagnostics, report:

```text
independent re-run inconclusive due to execution limit
```

Do not call the timeout a test failure, and do not claim independent
confirmation.

---

# Artifact integrity

## Canonical `current-*` must be actually current

Check provenance for all relevant files:

```text
current.json
current-counters.json
current-profile-index.json
current-differential-profile.json
current-codesize.json
current-callframe-layout.json
current-dispatch-floor.json
current-matrix.json
current-smoke.json
```

Look for:

```text
git_head
measured_source_head
source_dirty
artifact_dirty
binary hash
PUC hash
timestamp
```

All final `current-*` files should refer to one coherent final measured source,
unless the file explicitly documents that it is historical.

A mixed set such as:

```text
current.json        -> final source
current-profile     -> previous phase
current-layout      -> phase entry
```

is a provenance problem even if the contents happen to remain valid.

Do not call heterogeneous artifacts `current`.

## Artifact content may be valid while provenance is stale

Distinguish:

```text
semantic/layout content still correct
vs
artifact provenance not final
```

Do not overstate a stale SHA as a runtime bug.

---

# Architecture review checklist

## PC / dispatch ownership

Check:

- one canonical PC representation;
- boundary publication only where needed;
- hook/error/GC attribution correctness;
- no duplicate index+pointer mutable state;
- no per-fetch work reintroduced accidentally.

Historical important result:

- full pointer cursor reduced instructions but caused large wall/IPC
  regressions on arithmetic workloads;
- do not repeat it blindly.

A future PC experiment must be a genuinely different representation and must
use strict A/B evidence.

## Thread/runtime ownership

Current desired architecture:

```text
Thread always owns its bytecode stack/top/boxed/TBC runtime storage.
Vm selects the executing Thread.
```

Reject resurrection of:

```text
active Vm stack ownership
parkActiveRuntime
activateRuntime
active-vs-parked copies
```

Check stale comments too.

## Error state

Semantic error identity/state should be thread-owned.

Scratch rendering buffers may stay VM-owned.

Look for cross-thread semantic state leaks.

Synthetic C-frame attribution should be structurally derived from the current
frame chain rather than from sticky global labels.

## Coroutine/trampoline ownership

Core invariant:

> A trampoline may switch threads only when every continuation it crosses is
> represented in VM-owned Thread/CallFrame state.

If a native Zig/C-like caller has live host-stack continuation state:

- resume synchronously;
- return to that caller;
- do not unwind it into an iterative trampoline that cannot restore it.

Check:

```text
drive-thread ownership
boundary depth
nested host-recursive runBytecodeInternal
pure Lua iterative resume
```

## Non-yieldable C boundaries

Compare with PUC `ccall` / `luaD_callnoyield`.

The `nny` unit should be owned structurally by the C-call boundary.

Enter it before child activation if CALL hooks must observe the boundary.

Reject function-identity checks like:

```text
if comparator == coroutine_yield
```

when a proper C-call boundary solves the class generically.

## Yielded values

Preferred model:

```text
values remain in the yielding Thread stack
Thread stores logical span/index metadata
resumer copies/moves values when consuming them
```

Avoid persistent raw slices into reallocatable stacks.

Cold/native paths may use owned storage when lifetime requires it.

Verify:

- GC roots;
- realloc safety;
- debug suspended-frame semantics;
- multi-value results;
- >inline capacity;
- close/error paths.

## CallFrame / frame transitions

CallFrame size is a major invariant.

Historically:

```text
CallFrame = 88 B
LuaFrameState = 48 B
```

Measure, do not assume.

Review:

- frame push;
- frame pop;
- activation writes;
- parent return;
- TBC;
- hook state;
- pending continuations;
- heap/inline FrameStack spill boundaries.

Before proposing "add a fast return path", inspect whether one already exists.

Do not duplicate call semantics.

---

# Performance review methodology

## 1. Prefer dynamic instructions for causal attribution

Wall time alone is not enough.

For a proposed cut collect:

```text
instructions
cycles
IPC
branches
branch misses
wall
code size
```

The dispatcher is highly frontend/layout-sensitive.

A common failure mode is:

```text
instructions -4%
wall +25%
IPC collapses
```

That is a REJECT unless there is an extremely compelling correctness reason.

## 2. Use immutable A/B binaries

For every serious perf cut:

1. build baseline;
2. copy binary to immutable path;
3. hash it;
4. build candidate;
5. copy candidate;
6. hash it;
7. re-check hashes before perf runs.

Some gate scripts rebuild `zig-out`.

Do not accidentally benchmark the wrong binary.

## 3. Separate wall noise from structural regressions

If:

```text
instructions identical
wall differs
```

repeat A/B and inspect:

- cycles;
- IPC;
- code size;
- dispatch layout.

The project has documented binary-layout lottery.

Do not attribute a wall shift to source semantics without evidence.

## 4. Fresh profiles after every major cut

Never choose the next target from a stale profile.

Regenerate:

```text
current counters
profile index
differential profile
code size
kernel-specific decomposition
```

after the final accepted cut.

---

# Dispatch review methodology

Do not call all work inside `runBytecodeDispatch` "dispatch floor".

Separate:

```text
shared fetch/head
opcode-specific semantics
frame-loop entry/re-entry
OP_CALL front-half
frame activation
RETURN/parent completion
hook probes
GC probes
result staging
builtin machinery
coroutine machinery
```

A large function-level attribution is not a causal decomposition.

## True floor microkernel

Use a minimal steady-state loop such as FORLOOP and measure:

```text
instructions/iteration
cycles/iteration
IPC
wall
branches
branch misses
```

Compare luazig and PUC.

Record exact source SHA and binary hash.

Historical results become stale after dispatcher changes.

## Kernel matrix

Maintain small diagnostic kernels for:

```text
K1 pure FORLOOP
K2 arithmetic
K3 branch
K4 Lua call/return
K5 builtin call
K6 coroutine resume/yield
```

Use exact executed opcode counts where possible.

Do not infer "gap per opcode" when the engines execute materially different
bytecode without documenting the difference.

## Exact attribution

Prefer:

```text
callgrind --dump-instr
address-range slopes
objdump
addr2line
```

Be careful with inclusive line totals on a large inlined Zig function.

A source line can accumulate multiple inlined contexts.

When bucket labels were created on an older source, revalidate them after
major cuts.

---

# Builtin-call review

When builtin paths are hot, decompose:

```text
OP_CALL builtin selection
C-frame need classification
FrameStack add
C-frame initialization
args window / savestack
outs registration
active builtin identity/state
builtin dispatch
builtin semantic body
C-frame pop
TBC/owned-state checks
GC debt gate
result movement
```

Look for PUC-like opportunities such as:

- write only valid fresh C-frame fields;
- flag-gate slow state;
- derive builtin identity from current C frame where possible;
- avoid global semantic mode state;
- avoid work needed only by re-entrant builtins.

Do not special-case one builtin benchmark.

---

# Lua CALL/RETURN review

Before proposing a new fast path, inspect current code.

Current project history already contains:

- direct Lua child entry;
- direct RETURN0/RETURN1 parent return;
- parent PC advance;
- direct context restore;
- simple-result optimizations.

Remaining cost may instead be:

```text
FrameStack top/pop bookkeeping
activation stores
result contract decoding
parent ctx rehydration
hook/GC gates
frame spill abstractions
```

Measure the existing fast cycle.

Do not build a second call model.

---

# FrameStack review

Potential hot-path questions:

- does top-pop use a generic shrink routine?
- does inline-depth pop still write heap metadata?
- are retired-frame stores dead?
- are slot fields fully overwritten on reuse?
- does code cross inline/heap depth correctly?

Always test around inline capacity boundaries:

```text
31
32
33
64+
```

and with:

```text
yield
error
TBC
hooks
GC
```

---

# Semantic backlog discipline

Never let known parity debt silently disappear.

Typical carried items currently include:

```text
deep suspended debug frame-chain
dynamic-result/dofile window
tostring(function) identity
errored-coroutine TBC close timing
lua_settop TBC
resume-leftover window
luaL_traceback
gc_count_kb
double-traceback classes
classified locals/cstack/native_mem divergences
```

A review may reorder these based on severity/evidence.

Do not mark them fixed without an explicit reproducer + differential result.

---

# Dynamic-result windows

Be suspicious of constants such as:

```text
16
256
```

used as output limits.

Before increasing a fixed number, determine:

- is it a true VM/register semantic maximum?
- a temporary scratch convention?
- an accidental historical cap?

PUC MULTRET semantics are not "large fixed N".

Do not replace 16 with 256 and call the issue solved unless 256 is proven to
be the real architectural bound.

---

# Function tostring

Do not emulate PUC identity-style function formatting using fake addresses
derived from:

- enum values;
- builtin IDs;
- arbitrary hashes.

A real fix requires a real identity representation.

---

# Error/TBC timing

A known important parity class:

```text
PUC unrecoverable coroutine resume error:
    TBC obligations remain until reset/coroutine.close

luazig historical behavior:
    eager close during resume error unwind
```

This is an unwind-architecture issue, not a string/message issue.

---

# Code quality review

Look for:

- stale comments describing deleted architecture;
- dead fields/types;
- duplicated slow paths;
- deeply nested conditionals that encode semantic classes poorly;
- helpers that obscure rather than clarify ownership;
- large comptime tables with inconsistent formatting/provenance;
- helper names no longer matching behavior.

Good cleanup should make future reasoning easier.

Do not do speculative refactors unrelated to measured/current problems.

---

# Code-size review

Always track:

```text
total .text
runBytecodeDispatch
builtinCoroutineResume
callBuiltin
pushBuiltinCFrame
popBuiltinCFrame
major generic fail/error helper families
```

Cold code is not dynamically executed, but a very large code-size change can
still move hot layout.

Avoid saying:

```text
cold code = zero runtime cost
```

Prefer:

```text
not executed on the measured hot path; layout impact still possible
```

---

# Review severity model

## BLOCKER

- wrong semantics on valid Lua;
- crash;
- continuation loss;
- GC corruption;
- double free;
- mandatory gate actually failing;
- artifact claimed final but measurements are unusable.

## HIGH

- architectural special case masking a general invariant;
- stale profile drives next phase incorrectly;
- duplicated mutable ownership;
- accepted perf cut with strong wall regression.

## MEDIUM

- stale provenance;
- stale comments;
- incomplete artifact regeneration;
- misleading wording in report;
- unverified but plausible claim.

## LOW

- mechanical formatting issue;
- documentation polish;
- non-blocking naming.

Do not overstate a LOW issue as a runtime failure.

---

# Deciding whether to accept a phase

## Accept

A phase is acceptable when:

- its main correctness/performance claim is supported;
- no hidden BLOCKER remains from the phase;
- architecture is not made materially worse;
- perf claims are causally measured;
- gates are either verified or transparently limited;
- remaining issues are honestly documented.

An accepted phase may still have:

- stale provenance;
- fmt-only cleanup;
- known backlog;
- a noisy geomean;
- an independently unverified RF run.

State those precisely.

## Accept with correction

Use when:

- main runtime work is sound;
- report overstates a gate or provenance detail;
- next-phase queue should change.

## Reject / revert

Recommend rejection when:

- semantic regression is introduced;
- perf "win" is wall-only or disappears under causal metrics;
- instruction improvement causes severe structural wall regression;
- architecture adds unmaintainable duplicate state;
- a benchmark special case replaces a general invariant.

---

# Selecting the next phase

Do not simply copy the report's queue.

Rank targets using:

1. correctness severity;
2. absolute instruction gap;
3. fraction of real workloads affected;
4. architectural cleanliness of the fix;
5. confidence in the root cause;
6. implementation risk;
7. availability of focused differential tests.

Prefer:

```text
real correctness bug
>
large generic structural perf gap
>
smaller generic perf gap
>
cleanup
```

unless cleanup blocks trustworthy measurement.

---

# Mandatory next-phase prompt

After the review, generate next-agent prompt in a file.

Preferred filename:

```text
prompt.md
```

The prompt must include:

- verified input source SHA;
- measured baseline;
- toolchain;
- corrections found during review;
- explicit blocking tasks;
- architecture invariants;
- perf methodology;
- focused tests;
- KEEP/REVERT rules;
- full gate;
- final report format;
- "what not to do".

Do not only write the prompt inline in chat.

Provide the file as a downloadable artifact.

---

# Prompt-writing style

The next-agent prompt should be explicit enough that another strong coding
agent can execute without re-deriving the entire review.

Good:

```text
Current opReturn1 already has a direct Lua-parent fast arm.
Do not add another one.
Measure K4-R3/R6 first.
```

Bad:

```text
Optimize returns.
```

Good:

```text
current-differential-profile is stale at SHA X while current.json is SHA Y;
regenerate all current-* on one final binary before selecting a target.
```

Bad:

```text
refresh artifacts.
```

---

# Final review response format

Use a compact but technically dense structure.

## 1. Verdict

Example:

```text
P16.xx accepted.
```

or:

```text
P16.xx accepted with two review corrections.
```

Explain the main reason.

## 2. Confirmed findings

Summarize the important claims independently supported by source/artifacts.

## 3. Review findings

List only material discrepancies:

- gate mismatch;
- stale provenance;
- stale source comment;
- wrong queue assumption;
- hidden correctness issue.

Distinguish severity.

## 4. Next-phase recommendation

Explain what should actually be first and why.

Use fresh measurements.

## 5. Agent prompt

Write the generated agent prompt here:

```text
prompt.md
```

---

# Historical lessons to preserve

These are not immutable truths, but they are important prior evidence.

## Pointer cursor

A full pointer-PC representation reduced dynamic instructions but caused
large arithmetic wall regressions and IPC collapse.

Do not repeat without a materially different design.

## Dispatch floor

A historical `70 vs 28 i/iter` floor became `61 vs 28` after later cuts.

Never use old microbench artifacts as current truth.

## Code-layout lottery

Dead/cold changes have moved wall performance with identical instructions.

Always inspect instructions/cycles/IPC before attributing wall changes.

## Matrix integrity

A phase once initially claimed matrix green before the mandatory full matrix
revealed coroutine/debug regressions.

Always trust the actual mandatory gate, not a partial lane.

## Cross-thread error state

Sticky VM-global semantic error metadata caused real cross-coroutine
misattribution.

Semantic state should live with the Thread/frame that owns it.

## Non-yieldable boundaries

Function-identity checks for `coroutine.yield` failed to model real C-call
semantics.

Structural `nny` ownership fixed the whole class.

## Trampoline ownership

Global "trampoline active" was not enough.

Switching is legal only when continuation ownership is fully represented in
VM state.

## Permanent Thread stack ownership

Moving active stack storage between Vm and Thread created complexity and
switch cost.

Thread now permanently owns its execution storage; do not regress this model.

---

# The core question of every review

Do not ask only:

> Did the agent make the benchmark faster?

Ask:

> Did the phase move luazig toward a simpler, more PUC-faithful VM whose
> measured behavior is easier to explain?

A strong phase improves at least one of:

- semantic parity;
- ownership clarity;
- hot-path instruction count;
- test coverage;
- provenance quality;

without silently degrading the others.

