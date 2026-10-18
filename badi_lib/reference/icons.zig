//! Freedesktop icon lookup: theme icon name → absolute file path.
//!
//! Built once per scan by listing the standard theme dirs (no per-icon
//! stat storm).

const std = @import("std");
const Allocator = std.mem.Allocator;

const icon_sizes = [_][]const u8{ "48", "32", "64", "24", "22", "16", "96", "128", "192", "256", "384", "512", "scalable" };
const icon_contexts = [_][]const u8{ "apps", "status", "devices", "actions", "preferences", "places", "mimetypes" };
const icon_exts = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg" };

/// Icon theme index: theme icon name → absolute file path.
/// Raster beats svg; otherwise first found wins.
pub const IconIndex = struct {
    map: std.StringHashMap([]const u8),

    pub fn build(arena: Allocator, io: std.Io, home: ?[]const u8, data_home: ?[]const u8) Allocator.Error!IconIndex {
        var self: IconIndex = .{ .map = .init(arena) };
        // Flat pixmap-style dirs: files live directly inside.
        if (home) |h| {
            if (h.len > 0) {
                try self.listFiles(arena, io, try std.Io.Dir.path.join(arena, &.{ h, ".icons" }));
                try self.listFiles(arena, io, try std.Io.Dir.path.join(arena, &.{ h, ".local/share/flatpak/exports/share/icons" }));
            }
        }
        try self.listFiles(arena, io, "/var/lib/flatpak/exports/share/icons");
        try self.listFiles(arena, io, "/usr/share/pixmaps");
        // Themed dirs: <base>/<theme>/<size>/<context>/ and breeze-style
        // <base>/<theme>/<context>/<size>/. The user base is the resolved
        // data dir ($XDG_DATA_HOME or $HOME/.local/share); ~/.icons and
        // the user flatpak exports stay $HOME-based (legacy path and
        // flatpak hardcodes its location regardless of XDG).
        const themed = [_]?[]const u8{
            if (data_home) |d| try std.fs.path.join(arena, &.{ d, "icons" }) else null,
            "/usr/share/icons",
        };
        for (themed) |maybe_base| {
            const base = maybe_base orelse continue;
            for (try themeDirs(arena, io, base)) |theme| {
                for (icon_sizes) |size| {
                    const sized = if (std.mem.eql(u8, size, "scalable")) "scalable" else try std.fmt.allocPrint(arena, "{s}x{s}", .{ size, size });
                    for (icon_contexts) |ctx| {
                        try self.listFiles(arena, io, try std.fs.path.join(arena, &.{ base, theme, sized, ctx }));
                        try self.listFiles(arena, io, try std.fs.path.join(arena, &.{ base, theme, ctx, size }));
                    }
                }
            }
        }
        return self;
    }

    /// Installed theme names under `base`, hicolor/Adwaita first.
    fn themeDirs(arena: Allocator, io: std.Io, base: []const u8) Allocator.Error![]const []const u8 {
        var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return &.{};
        };
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        for ([_][]const u8{ "Adwaita", "hicolor" }) |preferred| {
            for (names.items, 0..) |name, i| {
                if (std.mem.eql(u8, name, preferred)) {
                    const v = names.orderedRemove(i);
                    try names.insert(arena, 0, v);
                    break;
                }
            }
        }
        return names.items;
    }

    fn listFiles(self: *IconIndex, arena: Allocator, io: std.Io, dirpath: []const u8) Allocator.Error!void {
        var dir = std.Io.Dir.cwd().openDir(io, dirpath, .{ .iterate = true }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            try self.consider(arena, dirpath, entry.name);
        }
    }

    /// Index one file. Unknown extensions are ignored, so dotted names
    /// like "org.gnome.Foo" only match on real image suffixes.
    fn consider(self: *IconIndex, arena: Allocator, dirpath: []const u8, filename: []const u8) Allocator.Error!void {
        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return;
        if (dot == 0) return;
        const ext = filename[dot + 1 ..];
        if (!isKnownExt(ext)) return;
        const raster = !std.ascii.eqlIgnoreCase(ext, "svg");
        // NB: key must be copied: entry names are invalidated by the next
        // iterator call, and a mutating key corrupts the map.
        const key = try arena.dupe(u8, filename[0..dot]);
        if (self.map.get(key)) |old| {
            if (!isSvgPath(old) or !raster) return; // raster wins, ties keep first
        }
        try self.map.put(key, try std.fs.path.join(arena, &.{ dirpath, filename }));
    }

    /// Resolve an Icon value to an absolute file, or null. Absolute paths
    /// are checked directly (extension appended when missing).
    pub fn resolve(self: *IconIndex, arena: Allocator, io: std.Io, icon: ?[]const u8) Allocator.Error!?[]const u8 {
        const name = icon orelse return null;
        if (name.len == 0) return null;
        if (std.mem.startsWith(u8, name, "/")) return try self.resolveAbsolute(arena, io, name);
        const key = stripKnownExt(name);
        return self.map.get(key);
    }

    fn resolveAbsolute(self: *IconIndex, arena: Allocator, io: std.Io, path: []const u8) Allocator.Error!?[]const u8 {
        _ = self;
        const base = std.fs.path.basename(path);
        if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
            if (dot > 0 and isKnownExt(base[dot + 1 ..])) {
                return if (existsFile(io, path)) path else null;
            }
        }
        var buf: [512]u8 = undefined;
        for (icon_exts) |e| {
            const cand = std.fmt.bufPrint(&buf, "{s}.{s}", .{ path, e }) catch continue;
            if (existsFile(io, cand)) return try arena.dupe(u8, cand);
        }
        return null;
    }
};

fn stripKnownExt(name: []const u8) []const u8 {
    const base = std.fs.path.basename(name);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return name;
    if (dot == 0 or !isKnownExt(base[dot + 1 ..])) return name;
    return name[0 .. name.len - (base.len - dot)];
}

fn isKnownExt(ext: []const u8) bool {
    for (icon_exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

fn isSvgPath(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".svg");
}

fn existsFile(io: std.Io, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "icon consider prefers raster, ignores unknown ext" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var index: IconIndex = .{ .map = .init(arena) };
    try index.consider(arena, "/t", "org.gnome.Foo.svg");
    try testing.expectEqualStrings("/t/org.gnome.Foo.svg", index.map.get("org.gnome.Foo").?);
    try index.consider(arena, "/t", "org.gnome.Foo.png");
    try testing.expectEqualStrings("/t/org.gnome.Foo.png", index.map.get("org.gnome.Foo").?);
    try index.consider(arena, "/t", "org.gnome.Foo.svg"); // tie keeps first
    try testing.expectEqualStrings("/t/org.gnome.Foo.png", index.map.get("org.gnome.Foo").?);
    try index.consider(arena, "/t", "weird.xyz");
    try testing.expect(index.map.get("weird") == null);
    const io = std.Io.Threaded.global_single_threaded.io();
    try testing.expect((try index.resolve(arena, io, "org.gnome.Foo.png")) != null); // ext stripped
    try testing.expect((try index.resolve(arena, io, null)) == null);
}
