//! Minimal .desktop parser for a launcher: list apps, launch apps.
//!
//! This deliberately covers only what the launcher needs:
//! listing ([Desktop Entry] Name/Icon/Comment/Keywords, locale-aware) and
//! launching (Exec expanded to argv, Terminal, Path working dir).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_file_size = 1 << 20;

/// One launchable application. Every string (and `argv`) is owned by the
/// `AppList.arena` and valid until `AppList.deinit`.
pub const App = struct {
    name: []const u8,
    /// Raw Exec value, unescaped, for display.
    exec: []const u8,
    /// `exec` expanded to an argument vector with field codes resolved and
    /// no launch targets (a launcher starts the app bare).
    argv: []const []const u8 = &.{},
    icon: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    /// Raw Keywords value, unescaped; match with substring search.
    keywords: ?[]const u8 = null,
    /// Working directory to launch in.
    path: ?[]const u8 = null,
    terminal: bool = false,
};

/// Owns every `App` handed out. Call `deinit` when done, then `gpa.free` is
/// not needed: the slice lives in the arena too.
pub const AppList = struct {
    arena: std.heap.ArenaAllocator,
    apps: []const App,

    pub fn deinit(self: *AppList) void {
        self.arena.deinit();
    }
};

/// Scan system + user `applications` dirs and return launchable apps only:
/// `Type=Application`, with `Name` and `Exec`, not `Hidden`/`NoDisplay`.
/// `locale` (e.g. "ar_EG.UTF-8", null = unlocalized) picks localized
/// Name/Icon/Comment. Unreadable files are skipped; only OOM is returned.
pub fn scan(gpa: Allocator, io: std.Io, home_dir: ?[]const u8, locale: ?[]const u8) Allocator.Error!AppList {
    var list: AppList = .{ .arena = .init(gpa), .apps = &.{} };
    errdefer list.arena.deinit();
    const arena = list.arena.allocator();

    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(gpa);
    try dirs.appendSlice(gpa, &.{ "/usr/share/applications", "/usr/local/share/applications" });

    var owned_user_dir: ?[]u8 = null;
    defer if (owned_user_dir) |d| gpa.free(d);
    if (home_dir) |home| {
        if (home.len > 0) {
            owned_user_dir = try std.fs.path.join(gpa, &.{ home, ".local/share/applications" });
            try dirs.append(gpa, owned_user_dir.?);
        }
    }

    var apps: std.ArrayList(App) = .empty;
    for (dirs.items) |desktop_dir| {
        var dir = std.Io.Dir.cwd().openDir(io, desktop_dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch break) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;
            const fs_path = std.fs.path.join(gpa, &.{ desktop_dir, entry.name }) catch |err| return err;
            defer gpa.free(fs_path);
            const source = std.Io.Dir.cwd().readFileAlloc(io, fs_path, gpa, .limited(max_file_size)) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                continue;
            };
            defer gpa.free(source);
            const app = try parseOne(arena, source, locale, fs_path);
            if (app) |a| try apps.append(arena, a);
        }
    }
    list.apps = try arena.dupe(App, apps.items);
    return list;
}

/// Parse one file; null when it is not a launchable app. Only OOM errors.
fn parseOne(arena: Allocator, source: []const u8, locale: ?[]const u8, fs_path: []const u8) Allocator.Error!?App {
    const copy = try arena.dupe(u8, source);
    const text = if (std.mem.startsWith(u8, copy, "\xEF\xBB\xBF")) copy[3..] else copy;

    var in_entry = false;
    var entry_done = false; // first [Desktop Entry] group already closed

    var type_v: ?[]const u8 = null;
    var exec: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var hidden = false;
    var no_display = false;
    var terminal = false;

    var name = localizedSlot{};
    var icon = localizedSlot{};
    var comment = localizedSlot{};
    var keywords: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
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
            if (key_locale == null) type_v = try unescape(arena, raw);
        } else if (std.mem.eql(u8, key, "Exec")) {
            if (key_locale == null) exec = try unescape(arena, raw);
        } else if (std.mem.eql(u8, key, "Path")) {
            if (key_locale == null) path = try unescape(arena, raw);
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
            if (key_locale == null) keywords = try unescape(arena, raw);
        }
    }

    if (type_v == null or !std.mem.eql(u8, type_v.?, "Application")) return null;
    const app_name = name.value() orelse return null;
    const app_exec = exec orelse return null;
    if (hidden or no_display) return null;

    const argv = expandExec(arena, app_exec, .{
        .icon = icon.value(),
        .name = app_name,
        .location = fs_path,
    }) catch return null;

    return .{
        .name = app_name,
        .exec = app_exec,
        .argv = argv,
        .icon = icon.value(),
        .comment = comment.value(),
        .keywords = keywords,
        .path = path,
        .terminal = terminal,
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
        const text = try unescape(arena, raw);
        const kl = key_locale orelse {
            if (self.plain == null) self.plain = text;
            return;
        };
        if (want == null) return;
        const rank = localeRank(kl, want.?);
        if (rank > self.best_rank) {
            self.best_rank = rank;
            self.best = text;
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

// ---------------------------------------------------------------- Exec

pub const ExecContext = struct {
    icon: ?[]const u8 = null,
    name: ?[]const u8 = null,
    location: ?[]const u8 = null,
};

pub const ExecError = error{
    MissingExec,
    UnterminatedQuote,
    InvalidFieldCode,
} || Allocator.Error;

/// Split an `Exec` value into argv, expanding field codes for a bare launch
/// (no files/URLs): lone `%f %F %u %U %c %k` vanish, lone `%F %U` yield
/// nothing, lone `%i` becomes `--icon <icon>`, `%%` is a literal `%`,
/// deprecated `%d %D %n %N %v %m` vanish, anything else is an error.
/// Quoting follows the spec: `"` groups, and inside quotes `\` escapes
/// only `"`, `` ` ``, `$` and `\`. Pass the unescaped value.
pub fn expandExec(arena: Allocator, exec: []const u8, ctx: ExecContext) ExecError![]const []const u8 {
    if (std.mem.trim(u8, exec, " \t\n").len == 0) return error.MissingExec;

    var argv: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < exec.len and isSpace(exec[i])) i += 1;
        if (i >= exec.len) break;

        var arg: std.ArrayList(u8) = .empty;
        var quoted = false;
        var literal = false;
        var codes: usize = 0;
        var last_code: u8 = 0;

        while (i < exec.len) : (i += 1) {
            const c = exec[i];

            if (c == '%') {
                i += 1;
                if (i >= exec.len) return error.InvalidFieldCode;
                const code = exec[i];
                switch (code) {
                    '%' => {
                        try arg.append(arena, '%');
                        literal = true;
                    },
                    'f', 'F', 'u', 'U' => {
                        codes += 1;
                        last_code = code;
                    },
                    'i' => {
                        codes += 1;
                        last_code = code;
                        if (ctx.icon) |v| try arg.appendSlice(arena, v);
                    },
                    'c' => {
                        codes += 1;
                        last_code = code;
                        if (ctx.name) |v| try arg.appendSlice(arena, v);
                    },
                    'k' => {
                        codes += 1;
                        last_code = code;
                        if (ctx.location) |v| try arg.appendSlice(arena, v);
                    },
                    'd', 'D', 'n', 'N', 'v', 'm' => {
                        codes += 1;
                        last_code = code;
                    },
                    else => return error.InvalidFieldCode,
                }
                continue;
            }

            if (quoted) {
                if (c == '"') {
                    quoted = false;
                } else if (c == '\\' and i + 1 < exec.len and std.mem.indexOfScalar(u8, "\"`$\\", exec[i + 1]) != null) {
                    i += 1;
                    try arg.append(arena, exec[i]);
                    literal = true;
                } else {
                    try arg.append(arena, c);
                    literal = true;
                }
            } else if (c == '"') {
                quoted = true;
                literal = true;
            } else if (isSpace(c)) {
                break;
            } else {
                try arg.append(arena, c);
                literal = true;
            }
        }
        if (quoted) return error.UnterminatedQuote;

        if (!literal and codes == 1 and last_code == 'i') {
            if (ctx.icon) |icon| {
                if (icon.len > 0) {
                    try argv.append(arena, "--icon");
                    try argv.append(arena, icon);
                }
            }
        } else if (!literal and codes > 0 and arg.items.len == 0) {
            // only field codes, expanded to nothing: drop the argument
        } else {
            try argv.append(arena, arg.items);
        }
    }
    return argv.items;
}

// ---------------------------------------------------------------- helpers

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// Resolve `\s \n \t \r \\`. Other escapes are kept as written.
/// Returns `raw` itself when there is nothing to resolve.
fn unescape(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;

    const buf = try arena.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            const replacement: ?u8 = switch (raw[i + 1]) {
                's' => ' ',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                else => null,
            };
            if (replacement) |r| {
                c = r;
                i += 1;
            }
        }
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
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

fn parseSample(arena: Allocator, locale: ?[]const u8) !?App {
    return parseOne(arena, sample, locale, "/usr/share/applications/firefox.desktop");
}

test "lists name, exec, icon" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const app = (try parseSample(arena_state.allocator(), null)).?;
    try testing.expectEqualStrings("Firefox", app.name);
    try testing.expectEqualStrings("firefox %u", app.exec);
    try testing.expectEqualStrings("firefox", app.icon.?);
    try testing.expectEqualStrings("Browse the Web", app.comment.?);
    try testing.expectEqualStrings("web;browser;", app.keywords.?);
    try testing.expectEqual(false, app.terminal);
    // bare launch: lone %u vanishes
    try testing.expectEqual(@as(usize, 1), app.argv.len);
    try testing.expectEqualStrings("firefox", app.argv[0]);
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
    try testing.expect(try parseOne(arena, "[Desktop Entry]\nType=Application\nName=X\nExec=x\nHidden=true\n", null, "x") == null);
    try testing.expect(try parseOne(arena, "[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=1\n", null, "x") == null);
    try testing.expect(try parseOne(arena, "[Desktop Entry]\nType=Link\nName=X\nURL=https://x\n", null, "x") == null);
    try testing.expect(try parseOne(arena, "[Desktop Entry]\nType=Application\nName=X\n", null, "x") == null);
    try testing.expect(try parseOne(arena, "[Other]\nName=X\n", null, "x") == null);
}

test "exec quoting and codes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try expandExec(arena, "sh -c \"echo \\\"hi\\\" 100%%\" %F", .{});
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("echo \"hi\" 100%", argv[2]);
    try testing.expectError(error.InvalidFieldCode, expandExec(arena, "prog %z", .{}));
    try testing.expectError(error.UnterminatedQuote, expandExec(arena, "prog \"open", .{}));
}
