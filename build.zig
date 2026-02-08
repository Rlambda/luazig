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

    const luazigc_exe = b.addExecutable(.{
        .name = "luazigc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/luazigc.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lua", .module = lua_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });
    b.installArtifact(luazigc_exe);

    const run_luazig_cmd = b.addRunArtifact(luazig_exe);
    run_luazig_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_luazig_cmd.addArgs(args);

    const run_step = b.step("run", "Run luazig");
    run_step.dependOn(&run_luazig_cmd.step);

    const lua_tests = b.addTest(.{ .root_module = lua_mod });
    const run_lua_tests = b.addRunArtifact(lua_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lua_tests.step);
}
