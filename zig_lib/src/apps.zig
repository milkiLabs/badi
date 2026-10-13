//! Launcher backend entry point: scan installed apps, search them, launch them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app = @import("app.zig");
const icons = @import("icons.zig");
const parse = @import("parse.zig");
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

    // $HOME is read here from libc instead of threading it through FFI/Dart.
    // The user data dir is resolved once and shared by app dirs and icons.
    const home = getenv("HOME");
    const data_home = try dataHome(arena, home, getenv("XDG_DATA_HOME"));
    var scanner = try Scanner.init(gpa, arena, io, locale, home, data_home);
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
    index: icons.IconIndex,
    /// File names already taken by a higher-precedence dir. Keys are
    /// arena copies: iterator names die on the next call.
    seen_ids: std.StringHashMap(void),
    found: std.ArrayList(App),

    fn init(gpa: Allocator, arena: Allocator, io: std.Io, locale: ?[]const u8, home: ?[]const u8, data_home: ?[]const u8) Allocator.Error!Scanner {
        return .{
            .gpa = gpa,
            .arena = arena,
            .io = io,
            .locale = locale,
            .index = try icons.IconIndex.build(arena, io, home, data_home),
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
        const one = try parse.parseOne(self.arena, source, self.locale, fs_path, &self.index, self.io);
        if (one) |a| {
            if (isKnownApp(self.found.items, a.name, a.argv)) return; // same app, other file
            try self.found.append(self.arena, a);
        }
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

/// Indices into `apps` whose name/comment/keywords/exec contain `query`
/// (ASCII case-insensitive; null/blank matches all). Sorted order is kept.
pub fn search(gpa: Allocator, items: []const App, query: ?[]const u8) Allocator.Error![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    const q = std.mem.trim(u8, query orelse "", " \t");
    if (q.len == 0) {
        for (items, 0..) |_, i| try out.append(gpa, i);
        return out.toOwnedSlice(gpa);
    }
    const ql = try text.lowerDup(gpa, q);
    defer gpa.free(ql);
    for (items, 0..) |a, i| {
        if (std.mem.indexOf(u8, a.hay, ql) != null) try out.append(gpa, i);
    }
    return out.toOwnedSlice(gpa);
}

pub const LaunchError = error{
    EmptyArgv,
    SpawnFailed,
} || Allocator.Error;

/// One lookup source for process env (e.g. `$HOME`, `$TERMINAL`); null
/// when missing. Reads libc directly: no allocation, no failure, no Io.
pub fn getenv(key: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(key.ptr) orelse return null;
    return std.mem.span(v);
}

/// The live process environment as an `Environ.Map`, built once from libc
/// `environ` and cached for the life of the process. Every spawn gets this
/// map explicitly: the library's internal Io defaults to an empty
/// environment (which is what produced children with no HOME/DISPLAY/DBUS
/// locale), so children never rely on inheritance. Linux-only, like the
/// rest of this backend. Backed by the C allocator, so there is nothing to
/// free; sequential use only, like the rest of this API.
var env_map_storage: std.process.Environ.Map = undefined;
var env_map_ready = false;

fn launchEnv() *const std.process.Environ.Map {
    if (!env_map_ready) {
        env_map_storage = .init(std.heap.c_allocator);
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const line = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (eq == 0) continue;
            // OOM here degrades to a partial map rather than failing the
            // spawn; the alternative is refusing to launch at all.
            env_map_storage.put(line[0..eq], line[eq + 1 ..]) catch break;
        }
        env_map_ready = true;
    }
    return &env_map_storage;
}

/// Spawn `app` and return immediately (no waiting: the child outlives the
/// launcher). `terminal_emulator` wraps terminal apps (`$TERMINAL`
/// resolved by the caller, null falls back to "x-terminal-emulator").
pub fn launch(gpa: Allocator, io: std.Io, item: App, terminal_emulator: ?[]const u8) LaunchError!void {
    if (item.argv.len == 0) return error.EmptyArgv;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    if (item.terminal) {
        try argv.append(gpa, terminal_emulator orelse "x-terminal-emulator");
        try argv.append(gpa, "-e");
    }
    try argv.appendSlice(gpa, item.argv);
    const cwd: std.process.Child.Cwd = if (item.path) |p| .{ .path = p } else .inherit;
    // The child must not inherit our pipes: they close when the launcher
    // exits, and inheriting them is exactly how GUI apps used to die on
    // their first log write. /dev/null never breaks.
    _ = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = cwd,
        .environ_map = launchEnv(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.SpawnFailed;
    };
}

fn lessByName(_: void, a: App, b: App) bool {
    return text.asciiLessThan(a.name, b.name);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "search matches blob, blank matches all" {
    const haystacks = [_]App{
        .{ .name = "Firefox", .hay = "firefox browse the web web;browser; firefox %u " },
        .{ .name = "Terminal", .hay = "terminal shell terminal " },
    };
    const all = try search(testing.allocator, &haystacks, null);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);

    const blank = try search(testing.allocator, &haystacks, "   ");
    defer testing.allocator.free(blank);
    try testing.expectEqual(@as(usize, 2), blank.len);

    const fire = try search(testing.allocator, &haystacks, "FIRE");
    defer testing.allocator.free(fire);
    try testing.expectEqual(@as(usize, 1), fire.len);
    try testing.expectEqual(@as(usize, 0), fire[0]);

    const none = try search(testing.allocator, &haystacks, "zzz");
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

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

test "launch rejects empty argv" {
    const io = std.Io.Threaded.global_single_threaded.io();
    try testing.expectError(error.EmptyArgv, launch(testing.allocator, io, .{ .name = "X" }, null));
}

test "launch env carries parent variables" {
    const path = getenv("PATH");
    try testing.expect(path != null and path.?.len > 0);
    try testing.expect(getenv("BADI_NO_SUCH_VAR_XYZ") == null);
    // The spawn map is built from the same source, so it agrees.
    // (Process-lifetime cache on the C allocator: nothing to free.)
    try testing.expectEqualStrings(path.?, launchEnv().get("PATH").?);
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
