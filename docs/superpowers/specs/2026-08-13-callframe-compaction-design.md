# CallFrame Compaction Design — PUC-faithful <100B target

## Goal

Compact `CallFrame` from ~344B to <100B by removing dead/duplicated/derivable
fields, moving hook/debug state to thread-level or continuation-level storage,
and moving the rare `PendingCallSlot` payload out of the common frame.

## Constraints

- No PUC C-continuation machinery (`lua_callk`/`lua_pcallk`/`lua_yieldk`)
- No regressions: matrix 30/31, smoke 49/49, unit 146/146, perf OK
- `frame_loop` preserved, no host recursion
- Ordinary Lua CALL/RETURN must not touch `PendingCallSlot`
- All `CallFrame*` pointers must be reacquired after reentrant operations

## Current CallFrame (~344B)

```
proto: ?*const bc.Proto          8B   — KEEP (discriminator: null=IR/C, non-null=Lua)
pc: usize                        8B   — KEEP (hot, PUC savedpc equivalent)
current_line: i64                8B   — REMOVE (derive from proto.lineinfo[pc])
last_hook_line: i64              8B   — REMOVE (move to Thread)
varargs: []Value                16B   — REMOVE (dead for bytecode frames; IR-only, derive from closure)
upvalues: []const *Cell         16B   — REMOVE (derive from bc_stack[func_slot].Closure.upvalues)
nvarstack: u32                   4B   — KEEP (dynamic, set by opForprep/opTailcall)
activation_id: usize             8B   — KEEP (frame identity for syncFrame safety)
base: usize                      8B   — KEEP (hot, PUC ci->func+1 equivalent)
func_slot: usize                 8B   — KEEP (PUC ci->func equivalent)
func_slot_base: usize            8B   — KEEP (TAILCALL reset, completeBytecodeExecFrame dst)
frame_cap: usize                 8B   — KEEP (hot, register window upper bound)
nextraargs: u16                  2B   — KEEP (PUC nextraargs, vararg hidden args)
callstatus: u32                  4B   — KEEP (PUC callstatus: nresults + flags)
resume_pc: usize                 8B   — COMPACT to u32 (hook-yield resume, pc < proto.code.len)
reg_top: u32                     4B   — KEEP (hot, GC liveness upper bound)
last_line_pc: ?usize            16B   — COMPACT to u32 sentinel (hook line tracking)
skip_line_hook_pc: ?usize       16B   — COMPACT to u32 sentinel (hook suppression)
tbc_mark: usize                  8B   — KEEP (TBC register stack mark)
pending_call: PendingCallSlot   ~64B  — MOVE to per-Thread sparse storage
skip_call_hook_pc: ?usize       16B   — COMPACT to u32 sentinel (hook suppression)
has_open_upvalues: bool          1B   — KEEP (close optimization)
env_override: ?Value            24B   — REMOVE (dead field, always null)
resume_skip_count_pc: ?usize    16B   — COMPACT to u32 sentinel (hook suppression)
debug_namewhat: ?[]const u8     24B   — REMOVE (move to Vm-level override with save/restore)
debug_name: ?[]const u8         24B   — REMOVE (move to Vm-level override with save/restore)
debug_hook_transfer: ?[]Value   24B   — REMOVE (move to Thread, hook-frame-only)
debug_hook_transfer_start: i64   8B   — REMOVE (move to Thread, hook-frame-only)
debug_hook_event_calllike: bool  1B   — REMOVE (move to Thread, hook-frame-only)
debug_hook_event_tailcall: bool  1B   — REMOVE (move to Thread, hook-frame-only)
debug_hook_event_is_count: bool  1B   — REMOVE (move to Thread, hook-frame-only)
debug_hook_allow_yield: bool     1B   — REMOVE (move to Thread, hook-frame-only)
```

## Target CallFrame (~72B)

```
proto: ?*const bc.Proto          8B
pc: usize                        8B
nvarstack: u32                   4B
callstatus: u32                  4B   (nresults + CIST_TAIL/HOOKED/HOOKYIELD/HIDE)
reg_top: u32                     4B
resume_pc: u32                   4B   (sentinel INVALID_PC = maxInt(u32) = no resume)
nextraargs: u16                  2B
has_open_upvalues: bool          1B
// padding: 1B
activation_id: usize             8B
base: usize                      8B
func_slot: usize                 8B
func_slot_base: usize            8B
frame_cap: usize                 8B
tbc_mark: usize                  8B
// hook pc sentinels (4 x u32):
last_line_pc: u32                4B   (INVALID_PC = none)
skip_line_hook_pc: u32           4B
skip_call_hook_pc: u32           4B
resume_skip_count_pc: u32        4B
// continuation handle:
continuation: u32                4B   (0 = none, index+1 into Thread.continuations)
```

Total: 8+8+4+4+4+4+2+1+1+8+8+8+8+8+8+4+4+4+4+4 = ~100B

Wait, let me recalculate:
- proto: 8
- pc: 8
- nvarstack: 4
- callstatus: 4
- reg_top: 4
- resume_pc: 4
- nextraargs: 2
- has_open_upvalues: 1
- padding: 1
- activation_id: 8
- base: 8
- func_slot: 8
- func_slot_base: 8
- frame_cap: 8
- tbc_mark: 8
- last_line_pc: 4
- skip_line_hook_pc: 4
- skip_call_hook_pc: 4
- resume_skip_count_pc: 4
- continuation: 4
- padding: 4

Total: 8+8+4+4+4+4+2+1+1+8+8+8+8+8+8+4+4+4+4+4+4 = 100B

Hmm, that's exactly 100B. Can we do better?

Actually, `activation_id` could be u32 (frame identity only needs to detect
reuse, and a u32 counter wraps at 4 billion frames). That saves 4B → 96B.

Or we could pack `nextraargs: u16` + `has_open_upvalues: bool` + 1 byte padding
into the existing u32 alignment gap. Let me reconsider the layout:

```
proto: ?*const bc.Proto          8B   (offset 0)
pc: usize                        8B   (offset 8)
activation_id: u32               4B   (offset 16)
callstatus: u32                  4B   (offset 20)
reg_top: u32                     4B   (offset 24)
resume_pc: u32                   4B   (offset 28)
nvarstack: u32                   4B   (offset 32)
nextraargs: u16                  2B   (offset 36)
has_open_upvalues: bool          1B   (offset 38)
continuation: u32                4B   (offset 40)  -- wait, alignment issue
```

Actually, let me just let Zig handle the layout. The key insight is:
- Remove ~244B of dead/duplicated/movable fields
- Pack optional usizes into u32 sentinels
- Move PendingCallSlot to per-Thread storage

## Design Decisions

### 1. Remove dead/duplicated fields

- **`varargs`** (16B): Dead for bytecode frames (uses `nextraargs` + bc_stack).
  IR frames derive from closure. Remove from CallFrame.
- **`env_override`** (24B): Always null, never set to non-null. Dead field. Remove.
- **`upvalues`** (16B): Derivable from `bc_stack[func_slot].Closure.upvalues`.
  Cache in `BytecodeDispatchCtx.cur_upvalues` (already done). Remove from CallFrame.
- **`current_line`** (8B): Derivable from `proto.lineinfo[pc]`. Compute on demand.
- **`last_hook_line`** (8B): Move to Thread (single-valued, like PUC `oldpc`).

### 2. Move hook/debug fields to Thread

These fields are ONLY used by debug hook frames (CIST_HOOKED). They are NOT
needed by ordinary Lua frames. Move them to Thread-level storage:

- **`debug_hook_transfer`**: Move to Thread (already duplicated at Vm level)
- **`debug_hook_transfer_start`**: Move to Thread (already duplicated at Vm level)
- **`debug_hook_event_calllike`**: Move to Thread (already duplicated at Vm level)
- **`debug_hook_event_tailcall`**: Move to Thread (already duplicated at Vm level)
- **`debug_hook_event_is_count`**: Move to Thread (already duplicated at Vm level)
- **`debug_hook_allow_yield`**: Move to Thread (already duplicated at Vm level)

The `activeAsyncDebugHookFrame()` mechanism scans the frame stack for a
CIST_HOOKED frame. Instead, store a `hook_frame_index: ?usize` on Thread
that tracks the active hook frame. When a hook frame is pushed, set the index;
when popped, clear it. This eliminates the O(n) scan.

### 3. Move debug_namewhat/debug_name to Vm-level

These are set on continuation-entered frames (metamethod, pairs, close). They
need to persist for the frame's lifetime. Use Vm-level save/restore:

- `vm.continuation_namewhat: ?[]const u8 = null`
- `vm.continuation_name: ?[]const u8 = null`

Set when pushing a continuation frame, restore the previous value when the
frame is popped. This works because continuation frames are pushed/popped in
LIFO order, and the Vm-level values are read by `debug.getinfo` which runs
while the frame is active.

### 4. Compact optional usize pc fields to u32 sentinels

Replace `?usize` (16B each) with `u32` (4B each) using `INVALID_PC = 0xFFFFFFFF`:

- `last_line_pc: u32`
- `skip_line_hook_pc: u32`
- `skip_call_hook_pc: u32`
- `resume_skip_count_pc: u32`
- `resume_pc: u32`

This saves 60B (5 × 12B). Pc values are bounded by `proto.code.len` which
fits in u32 for any realistic proto.

### 5. Move PendingCallSlot to per-Thread sparse storage

Replace inline `pending_call: PendingCallSlot` (~64B) with a `continuation: u32`
handle (4B). Value 0 = no continuation. Non-zero = index+1 into
`Thread.continuations: std.ArrayListUnmanaged(?BytecodePendingCall)`.

When a continuation is set:
1. Allocate a slot in `Thread.continuations` (or reuse a free slot)
2. Store the `BytecodePendingCall` there
3. Set `frame.continuation = slot_index + 1`

When a continuation is consumed/cleared:
1. Read `Thread.continuations[frame.continuation - 1]`
2. Clear the slot (set to null for reuse)
3. Set `frame.continuation = 0`

The `Thread.continuations` array is sparse — most frames never use a slot.
A simple free-list tracks reusable slots. The array is per-Thread, matching
PUC's per-lua_State CallInfo chain.

### 6. activation_id: u32 instead of usize

Frame identity counter only needs to detect frame reuse after pop/push.
A u32 counter (4 billion frames before wrap) is sufficient. Saves 4B.

## Implementation Order

1. Remove dead fields (`env_override`, `varargs` for bytecode)
2. Remove `upvalues` (derive from bc_stack[func_slot])
3. Remove `current_line` (derive from proto.lineinfo[pc])
4. Move `last_hook_line` to Thread
5. Move hook/debug fields to Thread (debug_hook_*, hook_frame_index)
6. Move `debug_namewhat`/`debug_name` to Vm-level save/restore
7. Compact `?usize` pc fields to `u32` sentinels
8. Move `PendingCallSlot` to per-Thread sparse storage
9. Compact `activation_id` to u32
10. Final size check + regression suite
