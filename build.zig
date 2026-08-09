const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util_mod = b.addModule("util", .{
        .root_source_file = b.path("src/util/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lua_mod = b.addModule("lua", .{
        .root_source_file = b.path("src/lua/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lua_mod.addImport("util", util_mod);

    const luazig_exe = b.addExecutable(.{
        .name = "luazig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/luazig.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lua", .module = lua_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });
    b.installArtifact(luazig_exe);
    // C extensions loaded via package.loadlib (dlopen) and the setjmp/longjmp
    // pcall boundary need libc linked into the host executables.
    luazig_exe.root_module.link_libc = true;

    // Export all symbols from the executable's dynamic symbol table so that
    // C extensions loaded via dlopen (package.loadlib) can resolve the
    // `lua_*` / `luaL_*` C API functions that c_api.zig exports. Mirrors
    // PUC Lua's Makefile `-Wl,-E` (`--export-dynamic`).
    luazig_exe.rdynamic = true;

    // --- Library targets: liblua.so / liblua.a for C drop-in linking ---
    //
    // Produces a shared library that C programs can link against:
    //   gcc app.c -Isrc/lua -Lzig-out/lib -llua -o app
    //
    // The library includes all `pub export fn` symbols from c_api.zig.
    // Linking libc is required for the setjmp/longjmp pcall boundary.
    const liblua = b.addLibrary(.{
        .name = "lua",
        .root_module = lua_mod,
        .linkage = .dynamic,
    });
    liblua.root_module.link_libc = true;
    b.installArtifact(liblua);

    // Static library for static linking scenarios.
    const liblua_static = b.addLibrary(.{
        .name = "lua",
        .root_module = lua_mod,
        .linkage = .static,
    });
    liblua_static.root_module.link_libc = true;
    b.installArtifact(liblua_static);

    const run_luazig_cmd = b.addRunArtifact(luazig_exe);
    run_luazig_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_luazig_cmd.addArgs(args);

    const run_step = b.step("run", "Run luazig");
    run_step.dependOn(&run_luazig_cmd.step);

    const lua_tests = b.addTest(.{ .root_module = lua_mod });
    lua_tests.root_module.link_libc = true;
    const run_lua_tests = b.addRunArtifact(lua_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lua_tests.step);
}
