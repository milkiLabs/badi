const std = @import("std");
const apps = @import("apps.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var list = try apps.scan(gpa, io, null);
    defer list.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("found {d} apps\n", .{list.apps.len});
    for (list.apps[0..@min(list.apps.len, 5)]) |app| {
        try out.print("  {s} icon={s}\n", .{ app.name, app.icon_path orelse "(none)" });
        try out.print("    argv:", .{});
        for (app.argv) |a| try out.print(" [{s}]", .{a});
        try out.print("\n", .{});
    }

    const hits = try apps.search(gpa, list.apps, "term");
    defer gpa.free(hits);
    try out.print("search \"term\": {d} hits\n", .{hits.len});
    for (hits[0..@min(hits.len, 3)]) |i| {
        try out.print("  {s}\n", .{list.apps[i].name});
    }

    try out.flush();
}
