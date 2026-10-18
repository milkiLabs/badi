//! Simplified Freedesktop Desktop Entry parsing: only the keys we care
//! about from the first `[Desktop Entry]` group (Type, Name, Icon, Exec).
//!
//! This is the "document file" parser used by the CLI and exposed over FFI.
//! It deliberately stays minimal (no locale, no exec expansion, no validation):
//! callers that need those layer them on top.

const std = @import("std");
const Allocator = std.mem.Allocator;

// keys that we care about in the [Desktop Entry] section
const Key = enum {
    Type,
    Name,
    Icon,
    Exec,
};

// Struct to hold the parsed values from the [Desktop Entry] section
pub const Document = struct {
    allocator: Allocator,

    Name: []const u8 = "",
    Type: []const u8 = "",
    Icon: []const u8 = "",
    Exec: []const u8 = "",

    pub fn init(allocator: Allocator) Document {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Document) void {
        if (self.Name.len > 0) self.allocator.free(self.Name);
        if (self.Type.len > 0) self.allocator.free(self.Type);
        if (self.Icon.len > 0) self.allocator.free(self.Icon);
        if (self.Exec.len > 0) self.allocator.free(self.Exec);
    }

    fn setOwned(self: *Document, field: *[]const u8, value: []const u8) !void {
        const dup = try self.allocator.dupe(u8, value);
        if (field.*.len > 0) self.allocator.free(field.*);
        field.* = dup;
    }

    pub fn format(self: Document, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Name: {s}\nType: {s}\nIcon: {s}\nExec: {s}\n", .{ self.Name, self.Type, self.Icon, self.Exec });
    }
};

pub fn parseDoc(allocator: Allocator, source: []const u8) !Document {
    var doc: Document = .init(allocator);
    errdefer doc.deinit();

    var lines = std.mem.splitScalar(u8, source, '\n');
    var in_desktop_entry = false;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (in_desktop_entry) break;
            const close = std.mem.findScalar(u8, line, ']') orelse continue;
            in_desktop_entry = std.mem.eql(u8, line[1..close], "Desktop Entry");
            continue;
        }
        if (!in_desktop_entry) continue;

        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const full_key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        const key = std.meta.stringToEnum(Key, full_key) orelse continue;

        switch (key) {
            .Type => try doc.setOwned(&doc.Type, value),
            .Name => try doc.setOwned(&doc.Name, value),
            .Icon => try doc.setOwned(&doc.Icon, value),
            .Exec => try doc.setOwned(&doc.Exec, value),
        }
    }
    return doc;
}

pub fn getDesktopDirs(allocator: Allocator) ![][]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;

    errdefer {
        for (dirs.items) |d| allocator.free(d);
        dirs.deinit(allocator);
    }

    const data_dirs: []const u8 = if (std.c.getenv("XDG_DATA_DIRS")) |v|
        std.mem.span(v)
    else
        "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, data_dirs, ':');
    while (it.next()) |base| {
        const trimmed = std.mem.trim(u8, base, " \t");
        if (trimmed.len == 0) continue;
        try dirs.append(allocator, try std.fmt.allocPrint(allocator, "{s}/applications", .{trimmed}));
    }

    const data_home: ?[]const u8 = blk: {
        if (std.c.getenv("XDG_DATA_HOME")) |v| {
            if (std.mem.span(v).len > 0) break :blk std.mem.span(v);
        }
        if (std.c.getenv("HOME")) |v| {
            if (std.mem.span(v).len > 0)
                break :blk try std.fmt.allocPrint(allocator, "{s}/.local/share", .{std.mem.span(v)});
        }
        break :blk null;
    };
    if (data_home) |home_share| {
        try dirs.append(allocator, try std.fmt.allocPrint(allocator, "{s}/applications", .{home_share}));
    }

    return dirs.toOwnedSlice(allocator);
}

pub fn getParsedDesktopEntries(allocator: Allocator, io: std.Io, desktop_dirs: [][]const u8) ![]Document {
    var docs: std.ArrayList(Document) = .empty;
    defer {
        for (docs.items) |*doc| doc.deinit();
        docs.deinit(allocator);
    }

    for (desktop_dirs) |desktop_dir| {
        const dir = std.Io.Dir.openDirAbsolute(io, desktop_dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = try std.mem.print(&path_buf, "{s}/{s}", .{ desktop_dir, entry.name });

            const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
            defer allocator.free(source);
            var doc = try parseDoc(allocator, source);

            if (!std.mem.eql(u8, doc.Type, "Application")) {
                doc.deinit();
                continue;
            }
            try docs.append(allocator, doc);
        }
    }
    return docs.toOwnedSlice(allocator);
}
