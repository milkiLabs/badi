const std = @import("std");
const parser = @import("desktop_parser.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var docs = try parser.parseAll(gpa, io, .{ .home_dir = init.environ_map.get("HOME") });
    defer {
        for (docs) |*d| d.deinit();
        gpa.free(docs);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("found {d} desktop files\n", .{docs.len});
    if (docs.len == 0) {
        try out.flush();
        return;
    }

    const show = @min(docs.len, 5);
    for (docs[0..show]) |*doc| {
        const e = doc.entry(null) catch |err| {
            try out.print("  <entry error: {s}>\n", .{@errorName(err)});
            continue;
        };
        doc.validate() catch |err| {
            try out.print("  {s}: invalid ({s})\n", .{ e.name, @errorName(err) });
            continue;
        };
        try out.print("  {s} [{s}] exec={s}\n", .{ e.name, @tagName(e.kind), e.exec orelse "(none)" });
    }

    try out.flush();
}
