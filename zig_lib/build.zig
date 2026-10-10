const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const lib = b.addLibrary(.{
        .name = "zig_lib",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = .safe,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);
}
