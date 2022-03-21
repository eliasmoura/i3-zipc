const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("i3ipc", "src/i3-ipc.zig");
    lib.setTarget(target);
    lib.setBuildMode(mode);
    lib.install();

    const lib_test = b.addTest("src/i3-ipc.zig");
    lib_test.setTarget(target);
    lib_test.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&lib_test.step);
}
