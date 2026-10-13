const std = @import("std");
const apps = @import("apps.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var list = try apps.scan(gpa, io, init.environ_map.get("HOME"), null);
    defer list.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("found {d} apps\n", .{list.apps.len});
    for (list.apps[0..@min(list.apps.len, 5)]) |app| {
        try out.print("  {s} exec={s}\n", .{ app.name, app.exec });
        try out.print("    argv:", .{});
        for (app.argv) |a| try out.print(" [{s}]", .{a});
        try out.print("\n", .{});
    }

    try out.flush();
}
