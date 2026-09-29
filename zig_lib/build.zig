const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    //   const optimize = b.standardOptimizeOption(.{});
    const optimize = .ReleaseFast;

    const lib = b.addLibrary(.{
        .name = "zig_lib",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);
}
