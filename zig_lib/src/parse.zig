//! One `.desktop` file → one launchable `app.App`, or null when the file
//! is not a visible `Type=Application` entry. Only `[Desktop Entry]` is
//! read; everything else is skipped without storing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("app.zig").App;
const exec = @import("exec.zig");
const icons = @import("icons.zig");
const text = @import("text.zig");

/// Parse one file; null when it is not a launchable app. Only OOM errors.
pub fn parseOne(arena: Allocator, source: []const u8, locale: ?[]const u8, fs_path: []const u8, index: *icons.IconIndex, io: std.Io) Allocator.Error!?App {
    const copy = try arena.dupe(u8, source);
    const body = if (std.mem.startsWith(u8, copy, "\xEF\xBB\xBF")) copy[3..] else copy;

    var in_entry = false;
    var entry_done = false; // first [Desktop Entry] group already closed

    var type_v: ?[]const u8 = null;
    var exec_value: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var hidden = false;
    var no_display = false;
    var terminal = false;

    var name = localizedSlot{};
    var icon = localizedSlot{};
    var comment = localizedSlot{};
    var keywords: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            if (in_entry) entry_done = true; // leaving the group we care about
            if (entry_done) break; // only the first [Desktop Entry] counts
            in_entry = line.len >= 3 and line[line.len - 1] == ']' and
                std.mem.eql(u8, line[1 .. line.len - 1], "Desktop Entry");
            continue;
        }
        if (!in_entry) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key_part = std.mem.trim(u8, line[0..eq], " \t");
        const raw = std.mem.trim(u8, line[eq + 1 ..], " \t");

        var key = key_part;
        var key_locale: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, key_part, '[')) |open| {
            if (key_part.len < open + 3 or key_part[key_part.len - 1] != ']') continue;
            key_locale = key_part[open + 1 .. key_part.len - 1];
            key = key_part[0..open];
        }

        if (std.mem.eql(u8, key, "Type")) {
            if (key_locale == null) type_v = try text.unescape(arena, raw);
        } else if (std.mem.eql(u8, key, "Exec")) {
            if (key_locale == null) exec_value = try text.unescape(arena, raw);
        } else if (std.mem.eql(u8, key, "Path")) {
            if (key_locale == null) path = try text.unescape(arena, raw);
        } else if (std.mem.eql(u8, key, "Hidden")) {
            if (key_locale == null) hidden = isTrue(raw);
        } else if (std.mem.eql(u8, key, "NoDisplay")) {
            if (key_locale == null) no_display = isTrue(raw);
        } else if (std.mem.eql(u8, key, "Terminal")) {
            if (key_locale == null) terminal = isTrue(raw);
        } else if (std.mem.eql(u8, key, "Name")) {
            try name.consider(arena, raw, key_locale, locale);
        } else if (std.mem.eql(u8, key, "Icon")) {
            try icon.consider(arena, raw, key_locale, locale);
        } else if (std.mem.eql(u8, key, "Comment")) {
            try comment.consider(arena, raw, key_locale, locale);
        } else if (std.mem.eql(u8, key, "Keywords")) {
            if (key_locale == null) keywords = try text.unescape(arena, raw);
        }
    }

    if (type_v == null or !std.mem.eql(u8, type_v.?, "Application")) return null;
    const app_name = name.value() orelse return null;
    const app_exec = exec_value orelse return null;
    if (hidden or no_display) return null;

    const app_icon = icon.value();
    const app_comment = comment.value();
    const argv = exec.expandExec(arena, app_exec, .{
        .icon = app_icon,
        .name = app_name,
        .location = fs_path,
    }) catch return null;

    // Lowercase search blob over the display/search fields.
    const parts = [_]?[]const u8{ app_name, app_comment, keywords, app_exec };
    const empty: []const u8 = "";
    var hay_len: usize = 0;
    for (&parts) |*p| hay_len += (p.* orelse empty).len + 1;
    const hay_buf = try arena.alloc(u8, hay_len);
    var n: usize = 0;
    for (&parts) |*p| {
        const s = p.* orelse empty;
        for (s) |c| {
            hay_buf[n] = std.ascii.toLower(c);
            n += 1;
        }
        hay_buf[n] = ' ';
        n += 1;
    }

    return .{
        .name = app_name,
        .argv = argv,
        .icon_path = try index.resolve(arena, io, app_icon),
        .comment = app_comment,
        .path = path,
        .terminal = terminal,
        .hay = hay_buf[0..n],
    };
}

// ---------------------------------------------------------------- locale

/// Tracks one localizable key: plain value plus best locale match.
/// Exact locale match beats lang-only match beats plain.
const localizedSlot = struct {
    plain: ?[]const u8 = null,
    best: ?[]const u8 = null,
    best_rank: u8 = 0,

    const Self = @This();

    fn consider(self: *Self, arena: Allocator, raw: []const u8, key_locale: ?[]const u8, want: ?[]const u8) Allocator.Error!void {
        const unescaped = try text.unescape(arena, raw);
        const kl = key_locale orelse {
            if (self.plain == null) self.plain = unescaped;
            return;
        };
        if (want == null) return;
        const rank = localeRank(kl, want.?);
        if (rank > self.best_rank) {
            self.best_rank = rank;
            self.best = unescaped;
        }
    }

    fn value(self: Self) ?[]const u8 {
        return self.best orelse self.plain;
    }
};

/// 2 = exact match, 1 = language match ("de" for "de_DE.UTF-8"), else 0.
fn localeRank(have: []const u8, want: []const u8) u8 {
    if (std.mem.eql(u8, have, want)) return 2;
    var lang = want;
    for (lang, 0..) |c, i| {
        if (c == '_' or c == '.' or c == '@') {
            lang = lang[0..i];
            break;
        }
    }
    if (lang.len > 0 and std.mem.eql(u8, have, lang)) return 1;
    return 0;
}

fn isTrue(raw: []const u8) bool {
    return std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sample =
    \\[Desktop Entry]
    \\Type=Application
    \\Name=Firefox
    \\Name[ar]=فايرفوكس
    \\Name[de]=Feuerfuchs
    \\Comment=Browse\sthe\sWeb
    \\Icon=firefox
    \\Exec=firefox %u
    \\Terminal=false
    \\Keywords=web;browser;
    \\
;

fn testIndex(arena: Allocator) icons.IconIndex {
    return .{ .map = .init(arena) };
}

fn parseSample(arena: Allocator, locale: ?[]const u8) !?App {
    var index = testIndex(arena);
    const io = std.Io.Threaded.global_single_threaded.io();
    return parseOne(arena, sample, locale, "/usr/share/applications/firefox.desktop", &index, io);
}

fn parseSrc(arena: Allocator, src: []const u8) !?App {
    var index = testIndex(arena);
    const io = std.Io.Threaded.global_single_threaded.io();
    return parseOne(arena, src, null, "x", &index, io);
}

test "lists name, comment, argv" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const app = (try parseSample(arena_state.allocator(), null)).?;
    try testing.expectEqualStrings("Firefox", app.name);
    try testing.expectEqualStrings("Browse the Web", app.comment.?);
    try testing.expectEqual(false, app.terminal);
    try testing.expect(app.icon_path == null); // empty test index
    // bare launch: lone %u vanishes
    try testing.expectEqual(@as(usize, 1), app.argv.len);
    try testing.expectEqualStrings("firefox", app.argv[0]);
    // search blob covers name, comment, keywords, exec
    for ([_][]const u8{ "fire", "browse", "web;", "firefox %u" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, app.hay, needle) != null);
    }
}

test "locale picks exact, then lang, then plain" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("فايرفوكس", (try parseSample(arena, "ar_EG.UTF-8")).?.name);
    try testing.expectEqualStrings("Feuerfuchs", (try parseSample(arena, "de_DE")).?.name);
    try testing.expectEqualStrings("Firefox", (try parseSample(arena, "fr_FR")).?.name);
}

test "skips hidden, wrong type, missing exec" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(try parseSrc(arena, "[Desktop Entry]\nType=Application\nName=X\nExec=x\nHidden=true\n") == null);
    try testing.expect(try parseSrc(arena, "[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=1\n") == null);
    try testing.expect(try parseSrc(arena, "[Desktop Entry]\nType=Link\nName=X\nURL=https://x\n") == null);
    try testing.expect(try parseSrc(arena, "[Desktop Entry]\nType=Application\nName=X\n") == null);
    try testing.expect(try parseSrc(arena, "[Other]\nName=X\n") == null);
}
