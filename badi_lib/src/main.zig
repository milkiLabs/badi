const std = @import("std");
const desktop = @import("desktop.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const desktop_dirs = try desktop.getDesktopDirs(gpa);
    defer {
        for (desktop_dirs) |dir| gpa.free(dir);
        gpa.free(desktop_dirs);
    }

    const docs = try desktop.getParsedDesktopEntries(gpa, io, desktop_dirs);
    defer {
        for (docs) |*doc| doc.deinit();
        gpa.free(docs);
    }

    for (docs) |doc| {
        std.debug.print("{f}\n", .{doc});
    }
    std.debug.print("Parsed {d} desktop entries\n", .{docs.len});
}
