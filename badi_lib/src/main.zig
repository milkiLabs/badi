const std = @import("std");
const session = @import("session.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var s = try session.Session.initApps(gpa, io, null);
    defer s.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("found {d} apps\n", .{s.count()});
    for (0..@min(s.count(), 5)) |i| {
        const e = s.row(i).?;
        try out.print("  {s} icon={s}\n", .{ e.title, e.icon orelse "(none)" });
    }

    try s.setQuery("term");
    try out.print("search \"term\": {d} hits\n", .{s.count()});
    for (0..@min(s.count(), 3)) |i| {
        try out.print("  {s}\n", .{ s.row(i).?.title });
    }

    try out.flush();
}
