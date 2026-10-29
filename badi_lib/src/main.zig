const std = @import("std");
const desktop = @import("desktop.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdin_buf: [1024 * 64]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    while (try stdin.takeDelimiter('\n')) |line| {
        try stdout.print("{s}\n", .{line});
    }
    try stdout.flush();
}
// pub fn main(init: std.process.Init) !void {
//     const io = init.io;
//     const gpa = init.gpa;
//
//     const desktop_dirs = try desktop.getDesktopDirs(gpa);
//     defer {
//         for (desktop_dirs) |dir| gpa.free(dir);
//         gpa.free(desktop_dirs);
//     }
//
//     const docs = try desktop.getParsedDesktopEntries(gpa, io, desktop_dirs);
//     defer {
//         for (docs) |*doc| doc.deinit();
//         gpa.free(docs);
//     }
//
//     for (docs) |doc| {
//         std.debug.print("{f}\n", .{doc});
//     }
//     std.debug.print("Parsed {d} desktop entries\n", .{docs.len});
// }
