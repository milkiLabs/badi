//! Launcher backend entry point: scan installed apps, search them, launch them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app = @import("app.zig");
const exec = @import("exec.zig");
const desktop = @import("desktop.zig");
const text = @import("text.zig");

pub const App = app.App;
pub const max_file_size = 1 << 20;

/// Owns every `App` handed out. Call `deinit` when done.
pub const AppList = struct {
    arena: std.heap.ArenaAllocator,
    apps: []const App,

    pub fn deinit(self: *AppList) void {
        self.arena.deinit();
    }
};

/// Scan system + user `applications` dirs and return launchable apps only:
/// `Type=Application`, with `Name` and `Exec`, not `Hidden`/`NoDisplay`.
/// Sorted by name. Duplicates are dropped: the same desktop file ID
/// (file name) or the same Name+Exec pair keeps only the copy from the
/// highest-precedence dir (user > local > system), per the spec's
/// shadowing rules. `locale` (e.g. "ar_EG.UTF-8", null = unlocalized)
/// picks localized Name/Icon/Comment. Unreadable files are skipped; only
/// OOM is returned.
pub fn scan(gpa: Allocator, io: std.Io, locale: ?[]const u8) Allocator.Error!AppList {
    var list: AppList = .{ .arena = .init(gpa), .apps = &.{} };
    errdefer list.arena.deinit();
    const arena = list.arena.allocator();

    const home = getenv("HOME");
    const data_home = try dataHome(arena, home, getenv("XDG_DATA_HOME"));
    var scanner = try Scanner.init(gpa, arena, io, locale);
    for (try appDirs(arena, data_home)) |maybe_dir| {
        // dir may be null HOME and XDG_DATA_HOME can both be unset
        const desktop_dir = maybe_dir orelse continue;
        try scanner.scanDir(desktop_dir);
    }
    std.mem.sort(App, scanner.found.items, {}, lessByName);
    list.apps = try arena.dupe(App, scanner.found.items);
    return list;
}

/// Resolve the user data dir per the XDG Base Directory spec:
/// `$XDG_DATA_HOME`, falling back to `$HOME/.local/share` when unset,
/// empty, or relative (relative paths are invalid per the spec). Null when
/// neither yields a dir. The XDG value is borrowed as-is; the fallback is
/// joined on `arena`.
fn dataHome(arena: Allocator, home: ?[]const u8, xdg_data_home: ?[]const u8) Allocator.Error!?[]const u8 {
    if (xdg_data_home) |x| {
        if (x.len > 0 and std.Io.Dir.path.isAbsolute(x)) return x;
    }
    if (home) |h| {
        if (h.len > 0) return try std.Io.Dir.path.join(arena, &.{ h, ".local/share" });
    }
    return null;
}

/// Desktop dirs in precedence order: the user dir first so its entries win
/// dedupe in `scan`. Built from the resolved user data dir (`dataHome`):
/// `$XDG_DATA_HOME/applications`, or `$HOME/.local/share/applications` by
/// fallback. Joined on `arena`, which outlives the scan.
fn appDirs(arena: Allocator, data_home: ?[]const u8) Allocator.Error![3]?[]const u8 {
    const user = if (data_home) |d| try std.Io.Dir.path.join(arena, &.{ d, "applications" }) else null;
    return .{ user, "/usr/local/share/applications", "/usr/share/applications" };
}

/// Per-scan working state, so `scan` stays an outline and the helpers below
/// take one `self` instead of six parameters. Everything is arena-owned:
/// no deinit needed.
const Scanner = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    locale: ?[]const u8,
    /// File names already taken by a higher-precedence dir. Keys are
    /// arena copies: iterator names die on the next call.
    seen_ids: std.StringHashMap(void),
    found: std.ArrayList(App),

    fn init(gpa: Allocator, arena: Allocator, io: std.Io, locale: ?[]const u8) Allocator.Error!Scanner {
        return .{
            .gpa = gpa,
            .arena = arena,
            .io = io,
            .locale = locale,
            .seen_ids = .init(arena),
            .found = .empty,
        };
    }

    /// Collect launchable apps from one `applications` dir. A missing or
    /// unreadable dir is skipped, like an unreadable file.
    fn scanDir(self: *Scanner, desktop_dir: []const u8) Allocator.Error!void {
        var dir = std.Io.Dir.cwd().openDir(self.io, desktop_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;
            try self.scanFile(desktop_dir, entry.name);
        }
    }

    /// Parse one `.desktop` file into `found`, unless a higher-precedence
    /// dir already claimed its file name. Unreadable/invalid files are
    /// skipped; only OOM is returned.
    fn scanFile(self: *Scanner, desktop_dir: []const u8, file_name: []const u8) Allocator.Error!void {
        // Claimed before parsing: the shadow wins even when this copy
        // is unreadable, invalid, or explicitly Hidden.
        if (self.seen_ids.contains(file_name)) return; // shadowed by higher-precedence dir
        try self.seen_ids.put(try self.arena.dupe(u8, file_name), {});
        const fs_path = try std.Io.Dir.path.join(self.arena, &.{ desktop_dir, file_name });
        const source = std.Io.Dir.cwd().readFileAlloc(self.io, fs_path, self.gpa, .limited(max_file_size)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return;
        };
        defer self.gpa.free(source);
        var doc = desktop.parseDoc(self.arena, source) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return;
        };
        defer doc.deinit();
        if (!std.mem.eql(u8, doc.Type, "Application")) return;
        if (doc.Name.len == 0 or doc.Exec.len == 0) return;
        const app_name = try self.arena.dupe(u8, doc.Name);
        const app_exec = try self.arena.dupe(u8, doc.Exec);
        const argv = exec.expandExec(self.arena, app_exec, .{
            .name = app_name,
            .location = fs_path,
        }) catch return;
        // Lowercase search blob over display/search fields.
        const parts = [_]?[]const u8{ app_name, app_exec };
        const empty: []const u8 = "";
        var hay_len: usize = 0;
        for (&parts) |*p| hay_len += (p.* orelse empty).len + 1;
        const hay_buf = try self.arena.alloc(u8, hay_len);
        var n: usize = 0;
        for (&parts) |*p| {
            const sval = p.* orelse empty;
            for (sval) |c| {
                hay_buf[n] = std.ascii.toLower(c);
                n += 1;
            }
            hay_buf[n] = ' ';
            n += 1;
        }
        const a: App = .{
            .name = app_name,
            .argv = argv,
            .comment = null,
            .path = null,
            .terminal = false,
            .hay = hay_buf[0..n],
        };
        if (isKnownApp(self.found.items, a.name, a.argv)) return;
        try self.found.append(self.arena, a);
    }
};

/// True when an app with this name and launch vector is already listed
/// (same app shipped under two file names).
fn isKnownApp(items: []const App, name: []const u8, argv: []const []const u8) bool {
    for (items) |a| {
        if (!std.mem.eql(u8, a.name, name)) continue;
        if (a.argv.len != argv.len) continue;
        var same = true;
        for (a.argv, argv) |x, y| {
            if (!std.mem.eql(u8, x, y)) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

/// One lookup source for process env (e.g. `$HOME`); null when missing.
/// Reads libc directly: no allocation, no failure, no Io. Used only to
/// locate data dirs during `scan`; spawning (and its environment) is the
/// frontend's job.
pub fn getenv(key: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(key.ptr) orelse return null;
    return std.mem.span(v);
}

fn lessByName(_: void, a: App, b: App) bool {
    return text.asciiLessThan(a.name, b.name);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "sort is case-insensitive by name" {
    var items = [_]App{
        .{ .name = "vlc" },
        .{ .name = "Firefox" },
        .{ .name = "blender" },
    };
    std.mem.sort(App, &items, {}, lessByName);
    try testing.expectEqualStrings("blender", items[0].name);
    try testing.expectEqualStrings("Firefox", items[1].name);
    try testing.expectEqualStrings("vlc", items[2].name);
}

test "getenv reads libc directly" {
    const path = getenv("PATH");
    try testing.expect(path != null and path.?.len > 0);
    try testing.expect(getenv("BADI_NO_SUCH_VAR_XYZ") == null);
}

test "same name and argv counts as known app" {
    const items = [_]App{
        .{ .name = "Vim", .argv = &.{"gvim"} },
    };
    try testing.expect(isKnownApp(&items, "Vim", &.{"gvim"}));
    try testing.expect(!isKnownApp(&items, "Vim", &.{"vim"}));
    try testing.expect(!isKnownApp(&items, "Emacs", &.{"gvim"}));
}

test "data home prefers XDG, falls back to HOME/.local/share" {
    const custom = try dataHome(testing.allocator, "/home/x", "/data/xdg");
    try testing.expectEqualStrings("/data/xdg", custom.?); // borrowed, nothing to free

    const fallback = try dataHome(testing.allocator, "/home/x", null);
    defer testing.allocator.free(fallback.?);
    try testing.expectEqualStrings("/home/x/.local/share", fallback.?);

    const empty_xdg = try dataHome(testing.allocator, "/home/x", "");
    defer testing.allocator.free(empty_xdg.?);
    try testing.expectEqualStrings("/home/x/.local/share", empty_xdg.?);

    const relative_xdg = try dataHome(testing.allocator, "/home/x", "rel/path");
    defer testing.allocator.free(relative_xdg.?);
    try testing.expectEqualStrings("/home/x/.local/share", relative_xdg.?);

    try testing.expect((try dataHome(testing.allocator, null, null)) == null);
    try testing.expect((try dataHome(testing.allocator, "", null)) == null);
}

test "app dirs put user dir first" {
    const with_user = try appDirs(testing.allocator, "/data/xdg");
    defer testing.allocator.free(with_user[0].?);
    try testing.expectEqualStrings("/data/xdg/applications", with_user[0].?);
    try testing.expectEqualStrings("/usr/local/share/applications", with_user[1].?);
    try testing.expectEqualStrings("/usr/share/applications", with_user[2].?);

    const without_user = try appDirs(testing.allocator, null);
    try testing.expect(without_user[0] == null);
    try testing.expectEqualStrings("/usr/local/share/applications", without_user[1].?);
}
