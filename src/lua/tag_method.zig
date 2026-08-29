// PUC Lua tag-method events — single source of truth for the TMS enum.
//
// Mirrors `lua-5.5.0/src/ltm.h:19-43` (the `TMS` enum). Both the VM
// (`vm.zig`) and the codegen (`codegen_bc.zig`) import `TmsEvent` from
// here, eliminating the duplicated numeric constants that previously
// existed in both files with "must match" comments.
//
// The ordering MUST match PUC exactly: only events `<= .eq` are cached
// in `Table.flags` (PUC `checknoTM` / `gfasttm`, `ltm.h:63-68`). Events
// above `.eq` (arithmetic, comparison, call, close) are NOT cached —
// they always do a hash lookup.
//
// Non-TMS metafields (`__pairs`, `__tostring`, `__name`, `__metatable`)
// are NOT part of this enum — PUC handles them via `luaL_getmetafield`
// (direct string lookup), not via `tmname[]`. They live in `MetaField`
// in `vm.zig` (VM-local, no cross-module consumer).
//
// This module is dependency-free: it imports nothing from vm.zig or
// codegen_bc.zig, only `std` if needed (currently not needed).

/// PUC Lua tag-method events (`ltm.h:19-43`). Backed by `u5` — 25 events
/// fit comfortably (5 bits → range 0..31). The integer values are the
/// C-field encoding used in MMBIN/MMBINI/MMBINK bytecode instructions:
/// when the preceding arithmetic op fails (non-numeric operands), the
/// VM reads C to determine which metamethod to dispatch.
pub const TmsEvent = enum(u5) {
    index = 0, // __index
    newindex = 1, // __newindex
    gc = 2, // __gc
    mode = 3, // __mode
    len = 4, // __len
    eq = 5, // __eq — last "fast" (cached) event
    // Non-cached events follow (not stored in flags bitfield):
    add, // __add
    sub, // __sub
    mul, // __mul
    mod, // __mod
    pow, // __pow
    div, // __div
    idiv, // __idiv
    band, // __band
    bor, // __bor
    bxor, // __bxor
    shl, // __shl
    shr, // __shr
    unm, // __unm
    bnot, // __bnot
    lt, // __lt
    le, // __le
    concat, // __concat
    call, // __call
    close, // __close
};

/// Whether `event` is in the PUC "fast access" zone (index..eq).
/// These are the events cached in `Table.flags` via `checknoTM` /
/// `gfasttm` (ltm.h:54 `maskflags`, ltm.h:63-68). Events above `.eq`
/// always do a full hash lookup — they are never cached.
///
/// Mirrors PUC's `TM_FAST_MAX` boundary (ltm.h:24: `TM_EQ` is the last
/// tag method with fast access).
pub fn isFastCached(event: TmsEvent) bool {
    return @intFromEnum(event) <= @intFromEnum(TmsEvent.eq);
}

/// PUC `luaT_eventname[]` (ltm.c) — short opname strings for
/// debug/traceback. Used ONLY on the cold metamethod path
/// (MMBIN/MMBINI/MMBINK/UNM/BNOT handlers) to set the debug name of
/// the child frame. The hot arithmetic fast path carries no string
/// at all — this function is never called when native arithmetic
/// succeeds.
///
/// This is the SINGLE derivation point for opname strings from
/// `TmsEvent`. Events not listed (index, newindex, gc, mode, call,
/// close) return the generic `"metamethod"` — PUC's `luaT_eventname[]`
/// only has entries for the arithmetic/comparison/concat/len/eq events.
pub fn opname(event: TmsEvent) []const u8 {
    return switch (event) {
        .index => "index",
        .newindex => "newindex",
        .gc => "gc",
        .mode => "mode",
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .mod => "mod",
        .pow => "pow",
        .div => "div",
        .idiv => "idiv",
        .band => "band",
        .bor => "bor",
        .bxor => "bxor",
        .shl => "shl",
        .shr => "shr",
        .unm => "unm",
        .bnot => "bnot",
        .concat => "concat",
        .len => "len",
        .eq => "eq",
        .lt => "lt",
        .le => "le",
        .call => "call",
        .close => "close",
    };
}
