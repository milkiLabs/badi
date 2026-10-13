//! Stateful picker core: one filtered, selectable list over either scanned
//! apps or piped input lines. Dart/Flutter owns rendering, stdin/stdout,
//! and the window; everything else (filter, selection, launch) lives here
//! so every frontend shares one tested implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const apps = @import("apps.zig");
const text = @import("text.zig");

/// One visible row: an app or one input line. Strings borrow from the
/// session arena; `app` locates the launch target in apps mode.
pub const Entry = struct {
    title: []const u8,
    subtitle: ?[]const u8,
    icon: ?[]const u8,
    hay: []const u8,
    app: ?usize,
};

pub const Session = struct {
    gpa: Allocator,
    list: apps.AppList, // owns the arena; every string borrows from it
    apps: []const App, // full list in apps mode; empty in lines mode
    entries: []const Entry,
    shown: std.ArrayList(usize), // gpa-owned indices into entries, reused per query
    selected: usize, // index into shown.items

    const App = apps.App;

    pub fn deinit(self: *Session) void {
        self.shown.deinit(self.gpa);
        self.list.deinit();
    }

    /// Apps-mode session: scan now, show all.
    pub fn initApps(gpa: Allocator, io: std.Io, locale: ?[]const u8) Allocator.Error!Session {
        var list = try apps.scan(gpa, io, locale);
        errdefer list.deinit();
        const arena = list.arena.allocator();
        const all = list.apps;
        const entries = try arena.alloc(Entry, all.len);
        for (all, 0..) |a, i| {
            entries[i] = .{
                .title = a.name,
                .subtitle = a.comment,
                .icon = a.icon_path,
                .hay = a.hay,
                .app = i,
            };
        }
        var shown: std.ArrayList(usize) = .empty;
        errdefer shown.deinit(gpa);
        try showAll(&shown, gpa, entries.len);
        return .{
            .gpa = gpa,
            .list = list,
            .apps = all,
            .entries = entries,
            .shown = shown,
            .selected = 0,
        };
    }

    /// Lines-mode session: copy `lines` (caller keeps ownership), show all.
    /// Lowercase blobs are built once here so filtering never re-lowers.
    pub fn initLines(gpa: Allocator, lines: []const []const u8) Allocator.Error!Session {
        var list: apps.AppList = .{ .arena = .init(gpa), .apps = &.{} };
        errdefer list.deinit();
        const arena = list.arena.allocator();
        const entries = try arena.alloc(Entry, lines.len);
        for (lines, 0..) |line, i| {
            const title = try arena.dupe(u8, line);
            entries[i] = .{
                .title = title,
                .subtitle = null,
                .icon = null,
                .hay = try text.lowerDup(arena, title),
                .app = null,
            };
        }
        var shown: std.ArrayList(usize) = .empty;
        errdefer shown.deinit(gpa);
        try showAll(&shown, gpa, entries.len);
        return .{
            .gpa = gpa,
            .list = list,
            .apps = &.{},
            .entries = entries,
            .shown = shown,
            .selected = 0,
        };
    }

    /// Re-filter on `query` (null/blank shows all, ASCII case-insensitive
    /// substring) and reset selection to the top.
    pub fn setQuery(self: *Session, query: ?[]const u8) Allocator.Error!void {
        const q = std.mem.trim(u8, query orelse "", " \t");
        self.shown.clearRetainingCapacity();
        if (q.len == 0) {
            for (0..self.entries.len) |i| try self.shown.append(self.gpa, i);
        } else {
            const ql = try text.lowerDup(self.gpa, q);
            defer self.gpa.free(ql);
            for (self.entries, 0..) |e, i| {
                if (std.mem.indexOf(u8, e.hay, ql) != null) try self.shown.append(self.gpa, i);
            }
        }
        self.selected = 0;
    }

    /// Move selection by `delta` rows, clamped. No-op when empty.
    pub fn moveSelected(self: *Session, delta: isize) void {
        const n = self.shown.items.len;
        if (n == 0) return;
        const cur: isize = @intCast(self.selected);
        const max: isize = @intCast(n - 1);
        self.selected = @intCast(std.math.clamp(cur + delta, 0, max));
    }

    /// Shown row count.
    pub fn count(self: *const Session) usize {
        return self.shown.items.len;
    }

    /// Selected row, or null when empty.
    pub fn selectedEntry(self: *const Session) ?Entry {
        if (self.selected >= self.shown.items.len) return null;
        return self.entries[self.shown.items[self.selected]];
    }

    /// Shown row `i` (display order), or null when out of range.
    pub fn row(self: *const Session, i: usize) ?Entry {
        if (i >= self.shown.items.len) return null;
        return self.entries[self.shown.items[i]];
    }

    /// Spawn shown row `i`. Lines mode has nothing to spawn.
    pub fn launch(self: *Session, io: std.Io, i: usize) apps.LaunchError!void {
        const e = self.row(i) orelse return error.EmptyArgv;
        const ai = e.app orelse return error.EmptyArgv;
        try apps.launch(self.gpa, io, self.apps[ai], apps.getenv("TERMINAL"));
    }
};

fn showAll(shown: *std.ArrayList(usize), gpa: Allocator, n: usize) Allocator.Error!void {
    shown.clearRetainingCapacity();
    for (0..n) |i| try shown.append(gpa, i);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "lines session shows all, filters, resets" {
    var s = try Session.initLines(testing.allocator, &.{ "Firefox", "Terminal", "foot" });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.count());

    try s.setQuery("term");
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expectEqualStrings("Terminal", s.selectedEntry().?.title);

    try s.setQuery("  FIRE  ");
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expectEqualStrings("Firefox", s.row(0).?.title);

    try s.setQuery("zzz");
    try testing.expectEqual(@as(usize, 0), s.count());
    try testing.expect(s.selectedEntry() == null);
    s.moveSelected(1); // no-op when empty

    try s.setQuery("");
    try testing.expectEqual(@as(usize, 3), s.count());
    try testing.expectEqual(@as(usize, 0), s.selected);
}

test "move clamps both directions" {
    var s = try Session.initLines(testing.allocator, &.{ "a", "b", "c" });
    defer s.deinit();
    s.moveSelected(1);
    try testing.expectEqual(@as(usize, 1), s.selected);
    s.moveSelected(10);
    try testing.expectEqual(@as(usize, 2), s.selected);
    s.moveSelected(-10);
    try testing.expectEqual(@as(usize, 0), s.selected);
    s.moveSelected(-1);
    try testing.expectEqual(@as(usize, 0), s.selected);
}

test "query resets selection, rows are display-ordered" {
    var s = try Session.initLines(testing.allocator, &.{ "alpha", "beta", "alphabet" });
    defer s.deinit();
    s.moveSelected(2);
    try s.setQuery("alph");
    try testing.expectEqual(@as(usize, 0), s.selected);
    try testing.expectEqualStrings("alpha", s.row(0).?.title);
    try testing.expectEqualStrings("alphabet", s.row(1).?.title);
    try testing.expect(s.row(2) == null);
}
