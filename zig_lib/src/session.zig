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
    entries: std.ArrayList(Entry), // arena-backed, grows with piped input
    shown: std.ArrayList(usize), // gpa-owned indices into entries, reused per query
    selected: usize, // index into shown.items
    query_lower: ?[]u8, // active filter, arena-owned; null shows all
    lines_mode: bool, // appendLines only makes sense for piped input

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
        var entries: std.ArrayList(Entry) = .empty;
        for (all, 0..) |a, i| {
            try entries.append(arena, .{
                .title = a.name,
                .subtitle = a.comment,
                .icon = a.icon_path,
                .hay = a.hay,
                .app = i,
            });
        }
        var shown: std.ArrayList(usize) = .empty;
        errdefer shown.deinit(gpa);
        try showAll(&shown, gpa, entries.items.len);
        return .{
            .gpa = gpa,
            .list = list,
            .apps = all,
            .entries = entries,
            .shown = shown,
            .selected = 0,
            .query_lower = null,
            .lines_mode = false,
        };
    }

    /// Lines-mode session: copy `lines` (caller keeps ownership), show all.
    /// Lowercase blobs are built once here so filtering never re-lowers.
    pub fn initLines(gpa: Allocator, lines: []const []const u8) Allocator.Error!Session {
        var list: apps.AppList = .{ .arena = .init(gpa), .apps = &.{} };
        errdefer list.deinit();
        const arena = list.arena.allocator();
        var entries: std.ArrayList(Entry) = .empty;
        try dupeEntries(&entries, arena, lines);
        var shown: std.ArrayList(usize) = .empty;
        errdefer shown.deinit(gpa);
        try showAll(&shown, gpa, entries.items.len);
        return .{
            .gpa = gpa,
            .list = list,
            .apps = &.{},
            .entries = entries,
            .shown = shown,
            .selected = 0,
            .query_lower = null,
            .lines_mode = true,
        };
    }

    /// Re-filter on `query` (null/blank shows all, ASCII case-insensitive
    /// substring) and reset selection to the top.
    pub fn setQuery(self: *Session, query: ?[]const u8) Allocator.Error!void {
        const q = std.mem.trim(u8, query orelse "", " \t");
        const arena = self.list.arena.allocator();
        self.query_lower = if (q.len == 0) null else try text.lowerDup(arena, q);
        self.shown.clearRetainingCapacity();
        try self.appendMatches(0);
        self.selected = 0;
    }

    /// Append piped lines (lines mode only); newcomers matching the active
    /// query join the view in arrival order. Selection is untouched so
    /// streaming never yanks the highlight.
    pub fn appendLines(self: *Session, lines: []const []const u8) AppendError!void {
        if (!self.lines_mode) return error.WrongMode;
        const arena = self.list.arena.allocator();
        const from = self.entries.items.len;
        try dupeEntries(&self.entries, arena, lines);
        try self.appendMatches(from);
    }

    /// Push indices of entries[from..] matching the stored query into the
    /// view. Blank query matches all.
    fn appendMatches(self: *Session, from: usize) Allocator.Error!void {
        if (self.query_lower) |ql| {
            for (self.entries.items[from..], from..) |e, i| {
                if (std.mem.indexOf(u8, e.hay, ql) != null) try self.shown.append(self.gpa, i);
            }
        } else {
            for (from..self.entries.items.len) |i| try self.shown.append(self.gpa, i);
        }
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
        return self.entries.items[self.shown.items[self.selected]];
    }

    /// Shown row `i` (display order), or null when out of range.
    pub fn row(self: *const Session, i: usize) ?Entry {
        if (i >= self.shown.items.len) return null;
        return self.entries.items[self.shown.items[i]];
    }

    /// Spawn shown row `i`. Lines mode has nothing to spawn.
    pub fn launch(self: *Session, io: std.Io, i: usize) apps.LaunchError!void {
        const e = self.row(i) orelse return error.EmptyArgv;
        const ai = e.app orelse return error.EmptyArgv;
        try apps.launch(self.gpa, io, self.apps[ai], apps.getenv("TERMINAL"));
    }
};

pub const AppendError = error{WrongMode} || Allocator.Error;

fn showAll(shown: *std.ArrayList(usize), gpa: Allocator, n: usize) Allocator.Error!void {
    shown.clearRetainingCapacity();
    for (0..n) |i| try shown.append(gpa, i);
}

/// Copy `lines` into arena-owned entries (title + lowercase blob each).
fn dupeEntries(entries: *std.ArrayList(Entry), arena: Allocator, lines: []const []const u8) Allocator.Error!void {
    for (lines) |line| {
        const title = try arena.dupe(u8, line);
        try entries.append(arena, .{
            .title = title,
            .subtitle = null,
            .icon = null,
            .hay = try text.lowerDup(arena, title),
            .app = null,
        });
    }
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

test "append extends view, filters newcomers, keeps selection" {
    var s = try Session.initLines(testing.allocator, &.{"alpha"});
    defer s.deinit();
    try s.setQuery("alph");
    try testing.expectEqual(@as(usize, 1), s.count());

    try s.appendLines(&.{ "beta", "alphabet soup", "gamma" });
    try testing.expectEqual(@as(usize, 2), s.count());
    try testing.expectEqualStrings("alpha", s.row(0).?.title);
    try testing.expectEqualStrings("alphabet soup", s.row(1).?.title);
    try testing.expectEqual(@as(usize, 0), s.selected);

    s.moveSelected(1);
    try s.appendLines(&.{"delta"}); // no match: view and selection untouched
    try testing.expectEqual(@as(usize, 2), s.count());
    try testing.expectEqual(@as(usize, 1), s.selected);

    try s.setQuery("");
    try testing.expectEqual(@as(usize, 5), s.count());
}

test "append to empty session revives selection" {
    var s = try Session.initLines(testing.allocator, &.{});
    defer s.deinit();
    try s.setQuery("x");
    try testing.expectEqual(@as(usize, 0), s.count());
    try testing.expect(s.selectedEntry() == null);

    try s.appendLines(&.{"xray"});
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expectEqualStrings("xray", s.selectedEntry().?.title);
}

test "append to apps session is rejected" {
    var s = try Session.initLines(testing.allocator, &.{"a"});
    defer s.deinit();
    // Lines mode accepts; apps mode has no lines to append to. Cover the
    // misuse path via a flipped flag (initApps needs real system dirs).
    s.lines_mode = false;
    try testing.expectError(error.WrongMode, s.appendLines(&.{"b"}));
}
