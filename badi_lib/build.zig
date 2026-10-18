const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "badi",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_cmd = b.step("run", "Run the executable");
    run_cmd.dependOn(&run_exe.step);

    // Unit tests (link libc: apps.zig reads the environment via std.c).
    const test_cmd = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/apps.zig", "src/exec.zig", "src/session.zig", "src/ffi.zig", "src/sysmon.zig", "src/desktop.zig" }) |file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .link_libc = true,
            }),
        });
        test_cmd.dependOn(&b.addRunArtifact(t).step);
    }
}
