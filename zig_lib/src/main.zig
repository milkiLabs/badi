//! Freedesktop.org Desktop Entry parser
//! Spec: https://specifications.freedesktop.org/desktop-entry/latest/

const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

// TODO: maybe make it 64KB?
pub const max_file_size = 1 << 20;

// ---------------------------------------------------------------- errors

pub const ParseError = error{
    /// A `Key=Value` line before any `[Group]` header.
    EntryOutsideGroup,
    /// A line starting with `[` that is not a complete `[Name]`.
    InvalidGroupHeader,
    /// A line that is not a comment, a header, or `Key=Value`.
    InvalidLine,
    /// A key with characters outside `A-Za-z0-9-`, or an empty `Key[]`.
    InvalidKey,
    /// The same group name twice.
    DuplicateGroup,
    /// The same key (and locale) twice in one group.
    DuplicateKey,
} || Allocator.Error;

pub const EntryError = error{MissingDesktopEntryGroup} || Allocator.Error;

pub const ValidationError = error{
    MissingDesktopEntryGroup,
    MissingType,
    MissingName,
    MissingExec,
    MissingUrl,
    InvalidBoolean,
    MissingActionGroup,
};

pub const ExecError = error{
    MissingExec,
    UnterminatedQuote,
    InvalidFieldCode,
} || Allocator.Error;

pub const Options = struct {
    /// false (defualt): skip anything that can't be understood and keep going,
    /// true: return the matching `parseError` on the first problem.
    strict: bool = false,
};

// ---------------------------------------------------------------- locale
/// `lang_COUNTRY.ENCODING@MODIFIER`. The encoding part is dropped.
// _COUNTRY, and @MODIFIER may be omitted following the spec.
pub const Locale = struct {
    lang: []const u8,
    country: ?[]const u8 = null,
    modifier: ?[]const u8 = null,

    pub fn parse(s: []const u8) Locale {
        var rest = s;
        var modifier: ?[]const u8 = null;
        if (std.mem.findScalar(u8, rest, '@')) |i| {
            // get the @MODIFIER part and drop it from rest
            modifier = rest[i + 1 ..];
            rest = rest[0..i];
        }
        if (std.mem.findScalar(u8, rest, '.')) |i| {
            // drop the .ENCODING part from rest
            rest = rest[0..i];
        }
        if (std.mem.findScalar(u8, rest, '_')) |i| {
            return .{
                .lang = rest[0..i],
                .country = rest[i + 1 ..],
                .modifier = modifier,
            };
        }
        // else: no _COUNTRY part
        return .{
            .lang = rest,
            .modifier = modifier,
        };
    }

    pub fn same(a: Locale, b: Locale) bool {
        return eql(u8, a.lang, b.lang) and optEql(a.country, b.country) and optEql(a.modifier, b.modifier);
    }
};

// ---------------------------------------------------------------- document model
pub const Entry = struct {
    key: []const u8,
    /// Set for `Key[locale]=...`, null for a plain `Key=...`.
    locale: ?Locale,
    /// The value as written in the file (trimmed), used for `;` lists.
    raw: []const u8,
    /// `raw` with the escapes `\s \n \t \r \\` resolved.
    value: []const u8,
};

/// Splits a `;` separated value without allocating. Items are trimmed, empty
/// items are skipped, and `\;` does not split. Items are still in raw form,
/// use `Group.getListAlloc` when you need `\;` and friends resolved.
pub const ListIterator = struct {
    rest: []const u8,

    pub fn next(self: *ListIterator) ?[]const u8 {
        while (self.rest.len > 0) {
            var i: usize = 0;
            while (i < self.rest.len and self.rest[i] != ';') : (i += 1) {
                // skip escaped `\;`. we don't split on literal semicolon
                if (self.rest[i] == '\\' and i + 1 < self.rest.len) i += 1;
            }
            const item = std.mem.trim(u8, self.rest[0..i], " \t");
            self.rest = if (i < self.rest.len) self.rest[i + 1 ..] else self.rest[i..];
            // skip empty items
            if (item.len > 0) return item;
        }
        return null;
    }
};

pub const Group = struct {
    name: []const u8,
    entries: []const Entry,

    /// Unlocalized entry for `key`. If the key is duplicated, the last one wins.
    pub fn find(self: Group, key: []const u8) ?Entry {
        var i = self.entries.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries[i];
            if (e.locale == null and eql(u8, e.key, key)) return e;
        }
        return null;
    }
    /// Best entry for a locale such as "ar_EG.UTF-8", using the spec's order:
    /// lang_COUNTRY@MODIFIER, lang_COUNTRY, lang@MODIFIER, lang, then the plain key.
    pub fn findLocalized(self: Group, key: []const u8, locale: ?[]const u8) ?Entry {
        // if no locale is given, return unlocalized entry
        const raw = locale orelse return self.find(key);
        const want = Locale.parse(raw);
        // if the lang is empty, or "c" or "POSIX", return unlocalized entry

        if (want.lang.len == 0 or
            eqlIgnoreCase(want.lang, "c") or
            eqlIgnoreCase(want.lang, "posix"))
        {
            return self.find(key);
        }

        const attempts = [_]struct { country: ?[]const u8, modifier: ?[]const u8 }{
            .{ .country = want.country, .modifier = want.modifier },
            .{ .country = want.country, .modifier = null },
            .{ .country = null, .modifier = want.modifier },
            .{ .country = null, .modifier = null },
        };

        for (attempts) |a| {
            var i = self.entries.len;
            while (i > 0) {
                i -= 1;
                const e = self.entries[i];
                // ignore entries without a locale.
                const l = e.locale orelse continue;
                if (eql(u8, e.key, key) and eql(u8, l.lang, want.lang) and
                    optEql(l.country, a.country) and optEql(l.modifier, a.modifier))
                {
                    return e;
                }
            }
        }
        // if no localized entry was found, return the unlocalized one
        return self.find(key);
    }

    // TODO: should we only have one function for localized and unlocalized?
    pub fn get(self: Group, key: []const u8) ?[]const u8 {
        return if (self.find(key)) |e| e.value else null;
    }

    pub fn getLocalized(self: Group, key: []const u8, locale: ?[]const u8) ?[]const u8 {
        return if (self.findLocalized(key, locale)) |e| e.value else null;
    }

    /// Accepts `true`/`false` in any case and `1`/`0`. The spec only allows exactly
    /// `true` and `false`, `Document.validate` reports the others. Null if missing or invalid.
    // TODO: should we return false for missing keys? and we have default vlaues for some keys
    pub fn getBool(self: Group, key: []const u8) ?bool {
        const v = self.get(key) orelse return null;
        if (std.ascii.eqlIgnoreCase(v, "true") or eql(u8, v, "1")) return true;
        if (std.ascii.eqlIgnoreCase(v, "false") or eql(u8, v, "0")) return false;
        return null;
    }

    pub fn getNumber(self: Group, key: []const u8) ?f64 {
        const v = self.get(key) orelse return null;
        return std.fmt.parseFloat(f64, v) catch null;
    }

    /// Allocation free iteration over a `;` list. Empty if the key is missing.
    pub fn getList(self: Group, key: []const u8) ListIterator {
        return .{ .rest = if (self.find(key)) |e| e.raw else "" };
    }

    /// The list as a slice with every item unescaped. Use an arena.
    pub fn getListAlloc(self: Group, arena: Allocator, key: []const u8) Allocator.Error![]const []const u8 {
        return decodeList(arena, if (self.find(key)) |e| e.raw else "");
    }

    pub fn getListLocalizedAlloc(self: Group, arena: Allocator, key: []const u8, locale: ?[]const u8) Allocator.Error![]const []const u8 {
        return decodeList(arena, if (self.findLocalized(key, locale)) |e| e.raw else "");
    }
};

/// Owns every string it hands out (and everything a `DesktopEntry` built from it
/// points to). Call `deinit` when done.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    groups: []const Group,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    /// First group with this name
    pub fn group(self: Document, name: []const u8) ?Group {
        for (self.groups) |g| {
            if (eql(u8, g.name, name)) return g;
        }
        return null;
    }

    pub fn desktopEntry(self: Document) ?Group {
        return self.group("Desktop Entry");
    }

    /// The `[Desktop Action <id>]` group.
    pub fn actionGroup(self: Document, id: []const u8) ?Group {
        const prefix = "Desktop Action ";
        for (self.groups) |g| {
            if (std.mem.startsWith(u8, g.name, prefix) and eql(u8, g.name[prefix.len..], id)) {
                return g;
            }
        }
        return null;
    }

    /// Checks the rules the spec puts on a file: `[Desktop Entry]` first, Type and
    /// Name present, Exec for applications (unless DBusActivatable), URL for links,
    /// strict booleans, and a group for every listed action. Returns the first problem.
    pub fn validate(self: Document) ValidationError!void {
        if (self.groups.len == 0 or !eql(u8, self.groups[0].name, "Desktop Entry")) {
            return ValidationError.MissingDesktopEntryGroup;
        }
        const g = self.groups[0];

        if (g.get("Name") == null) return ValidationError.MissingName;

        const type_str = g.get("Type") orelse return ValidationError.MissingType;
        switch (Kind.parse(type_str)) {
            .application => if (g.get("Exec") == null and !(g.getBool("DBusActivatable") orelse false)) return error.MissingExec,
            .link => if (g.get("URL") == null) return error.MissingUrl,
            .directory, .unknown => {},
        }

        for (bool_keys) |k| {
            const v = g.get(k) orelse continue;
            if (!eql(u8, v, "true") and !eql(u8, v, "false")) return error.InvalidBoolean;
        }

        var ids = g.getList("Actions");
        while (ids.next()) |id| {
            if (self.actionGroup(id) == null) return error.MissingActionGroup;
        }
    }

    /// Builds the typed view of `[Desktop Entry]`. Localized keys (Name, GenericName,
    /// Comment, Icon, Keywords) are resolved for `locale`. The result points into this
    /// document and is valid until `deinit`.
    pub fn entry(self: *Document, locale: ?[]const u8) EntryError!DesktopEntry {
        const g = self.desktopEntry() orelse return error.MissingDesktopEntryGroup;
        const alloc = self.arena.allocator();

        var actions: std.ArrayList(Action) = .empty;
        var ids = g.getList("Actions");
        while (ids.next()) |id| {
            const ag = self.actionGroup(id) orelse continue;
            try actions.append(alloc, .{
                .id = id,
                .name = ag.getLocalized("Name", locale) orelse "",
                .icon = ag.getLocalized("Icon", locale),
                .exec = ag.get("Exec"),
            });
        }
        return .{
            .group = g,
            .kind = if (g.get("Type")) |t| Kind.parse(t) else .unknown,
            .version = g.get("Version"),
            .name = g.getLocalized("Name", locale) orelse "",
            .generic_name = g.getLocalized("GenericName", locale),
            .comment = g.getLocalized("Comment", locale),
            .icon = g.getLocalized("Icon", locale),
            .no_display = g.getBool("NoDisplay") orelse false,
            .hidden = g.getBool("Hidden") orelse false,
            .only_show_in = try g.getListAlloc(alloc, "OnlyShowIn"),
            .not_show_in = try g.getListAlloc(alloc, "NotShowIn"),
            .dbus_activatable = g.getBool("DBusActivatable") orelse false,
            .try_exec = g.get("TryExec"),
            .exec = g.get("Exec"),
            .path = g.get("Path"),
            .terminal = g.getBool("Terminal") orelse false,
            .actions = actions.items,
            .mime_types = try g.getListAlloc(alloc, "MimeType"),
            .categories = try g.getListAlloc(alloc, "Categories"),
            .implements = try g.getListAlloc(alloc, "Implements"),
            .keywords = try g.getListLocalizedAlloc(alloc, "Keywords", locale),
            .startup_notify = g.getBool("StartupNotify"),
            .startup_wm_class = g.get("StartupWMClass"),
            .url = g.get("URL"),
            .prefers_non_default_gpu = g.getBool("PrefersNonDefaultGPU") orelse false,
            .single_main_window = g.getBool("SingleMainWindow") orelse false,
        };
    }
};

const bool_keys = [_][]const u8{
    "NoDisplay",
    "Hidden",
    "DBusActivatable",
    "Terminal",
    "StartupNotify",
    "PrefersNonDefaultGPU",
    "SingleMainWindow",
};

// ---------------------------------------------------------------- typed view

pub const Kind = enum {
    application,
    link,
    directory,
    unknown,

    pub fn parse(s: []const u8) Kind {
        if (eql(u8, s, "Application")) return .application;
        if (eql(u8, s, "Link")) return .link;
        if (eql(u8, s, "Directory")) return .directory;
        return .unknown;
    }
};

pub const LaunchOptions = struct {
    /// Files or URLs to open. Used by %f %F %u %U, see `expandExec`.
    targets: []const []const u8 = &.{},
    /// Where the .desktop file lives, used by %k.
    location: ?[]const u8 = null,
};

pub const Action = struct {
    id: []const u8,
    name: []const u8,
    icon: ?[]const u8,
    exec: ?[]const u8,

    /// Same as `DesktopEntry.argv`, with the action's own Name (%c) and Icon (%i).
    pub fn argv(self: Action, arena: Allocator, opts: LaunchOptions) ExecError![]const []const u8 {
        const exec = self.exec orelse return error.MissingExec;
        return expandExec(arena, exec, .{
            .targets = opts.targets,
            .icon = self.icon,
            .name = self.name,
            .location = opts.location,
        });
    }
};

///  Every key of the `[Desktop Entry]` group that the spec defines.
/// Strings borrow from the `Document`. Anything else (X-... keys) is reachable through `group`.
pub const DesktopEntry = struct {
    group: Group,

    kind: Kind = .unknown, // type
    version: ?[]const u8 = null,
    name: []const u8 = "", // localized
    generic_name: ?[]const u8 = null, // localized
    comment: ?[]const u8 = null, // localized
    icon: ?[]const u8 = null, // localized
    no_display: bool = false,
    hidden: bool = false,
    only_show_in: []const []const u8 = &.{},
    not_show_in: []const []const u8 = &.{},
    dbus_activatable: bool = false,
    try_exec: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    path: ?[]const u8 = null,
    terminal: bool = false,
    actions: []const Action = &.{},
    mime_types: []const []const u8 = &.{},
    categories: []const []const u8 = &.{},
    implements: []const []const u8 = &.{},
    keywords: []const []const u8 = &.{}, // localized
    startup_notify: ?bool = null,
    startup_wm_class: ?[]const u8 = null,
    url: ?[]const u8 = null,
    prefers_non_default_gpu: bool = false,
    single_main_window: bool = false,

    /// Case-sensitive, e.g. `entry.hasCategory("Education")`
    pub fn hasCategory(self: DesktopEntry, wanted: []const u8) bool {
        return contains(self.categories, wanted);
    }

    pub fn hasMimeType(self: DesktopEntry, wanted: []const u8) bool {
        return contains(self.mime_types, wanted);
    }

    pub fn action(self: DesktopEntry, id: []const u8) ?Action {
        for (self.actions) |a| {
            if (eql(u8, a.id, id)) return a;
        }
        return null;
    }

    /// Whether a menu or launcher running in `current_desktops` (the entries of
    /// XDG_CURRENT_DESKTOP split on ':') should list this entry.
    pub fn showInMenu(self: DesktopEntry, current_desktops: []const []const u8) bool {
        if (self.hidden or self.no_display) return false;
        if (self.only_show_in.len > 0 and !anyIn(self.only_show_in, current_desktops)) return false;
        if (anyIn(self.not_show_in, current_desktops)) return false;
        return true;
    }

    /// `Exec` as an argument vetor, see `expandExec`. Allocate from an arena.
    pub fn argv(self: DesktopEntry, arena: Allocator, opts: LaunchOptions) ExecError![]const []const u8 {
        const exec = self.exec orelse return error.MissingExec;
        return expandExec(arena, exec, .{
            .targets = opts.targets,
            .icon = self.icon,
            .name = self.name,
            .location = opts.location,
        });
    }
};

// ---------------------------------------------------------------- parsing

/// `source` is only read during the call, the result doesn't borrow from it.
pub fn parse(gpa: Allocator, source: []const u8, options: Options) ParseError!Document {
    var doc: Document = .{ .arena = .init(gpa), .groups = &.{} };
    errdefer doc.arena.deinit();
    const arena = doc.arena.allocator();

    // One copy of the input: names, keys and raw values are slices of it.
    const copy = try arena.dupe(u8, source);
    // Drop a UTF-8 BOM if present.
    const text = if (std.mem.startsWith(u8, copy, "\xEF\xBB\xBF")) copy[3..] else copy;

    var groups: std.ArrayList(Group) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    var current: ?[]const u8 = null; // name of the open group
    var skipping = false; // inside a group whose header was unreadable

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue; // blank or comment

        if (line[0] == '[') {
            // New group header. Save the previous one if any.
            if (current) |name| {
                try groups.append(arena, .{ .name = name, .entries = try arena.dupe(Entry, entries.items) });
                entries.clearRetainingCapacity();
            }
            // If the header is invalid, skip until the next one.
            if (line.len < 3 or line[line.len - 1] != ']') {
                if (options.strict) return error.InvalidGroupHeader;
                current = null;
                skipping = true;
                continue;
            }

            const name = line[1 .. line.len - 1];
            if (options.strict) {
                // Check for duplicate group names.
                for (groups.items) |g| {
                    if (eql(u8, g.name, name)) return error.DuplicateGroup;
                }
            }
            current = name;
            skipping = false;
            continue;
        }

        if (skipping) continue;
        if (current == null) {
            if (options.strict) return error.EntryOutsideGroup;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            if (options.strict) return error.InvalidLine;
            continue;
        };

        const key_part = std.mem.trim(u8, line[0..eq], " \t");
        const raw = std.mem.trim(u8, line[eq + 1 ..], " \t");

        var key = key_part;
        var locale: ?Locale = null;
        if (std.mem.indexOfScalar(u8, key_part, '[')) |open| {
            const close = key_part.len - 1;
            if (key_part[close] != ']' or close <= open + 1) {
                if (options.strict) return error.InvalidKey;
                continue;
            }
            locale = Locale.parse(key_part[open + 1 .. close]);
            key = key_part[0..open];
        }
        if (!isValidKey(key)) {
            if (options.strict) return error.InvalidKey;
            continue;
        }

        if (options.strict) {
            for (entries.items) |e| {
                if (eql(u8, e.key, key) and sameLocale(e.locale, locale)) return error.DuplicateKey;
            }
        }

        try entries.append(arena, .{
            .key = key,
            .locale = locale,
            .raw = raw,
            .value = try unescape(arena, raw, false),
        });
    }

    if (current) |name| {
        try groups.append(arena, .{ .name = name, .entries = try arena.dupe(Entry, entries.items) });
    }
    doc.groups = groups.items;
    return doc;
}

pub fn parseFile(gpa: Allocator, io: std.Io, path: []const u8, options: Options) !Document {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_size));
    defer gpa.free(source);
    return parse(gpa, source, options);
}

/// The desktop file ID of a file, given its path relative to an `applications` directory
/// "kde/foo.desktop" becomes "kde-foo.desktop". Caller frees.
pub fn desktopFileId(allocator: Allocator, relative_path: []const u8) Allocator.Error![]u8 {
    const id = try allocator.dupe(u8, relative_path);
    std.mem.replaceScalar(u8, id, '/', '-');
    return id;
}

// ---------------------------------------------------------------- Exec

pub const ExecContext = struct {
    /// Files or URLs for %f %F %u %U.
    targets: []const []const u8 = &.{},
    /// Icon name for %i.
    icon: ?[]const u8 = null,
    /// Translated application name for %c.
    name: ?[]const u8 = null,
    /// Path or URI of the .desktop file for %k.
    location: ?[]const u8 = null,
};

/// Splits an `Exec` value into arguments and expands field codes. Allocate from an arena.
///
/// Quoting: arguments are separated by spaces, double quotes group text, and inside
/// quotes a backslash escapes `"`, `` ` ``, `$` and `\`. Pass the already unescaped
/// value (`Entry.value`), the spec applies the string escapes first.
///
/// Field codes: a code that is a whole argument on its own expands like this.
///   %f %u   the first target, or nothing (the argument disappears)
///   %F %U   all targets, one argument each
///   %i      `--icon <icon>` as two arguments, or nothing without an icon
///   %c %k   name / location, or nothing
///   %%      a literal percent sign
/// Codes inside a longer argument (`--url=%u`) expand in place, and %F %U there
/// use the first target only. The deprecated %d %D %n %N %v %m expand to nothing.
/// Any other code is `error.InvalidFieldCode`.
pub fn expandExec(arena: Allocator, exec: []const u8, ctx: ExecContext) ExecError![]const []const u8 {
    if (std.mem.trim(u8, exec, " \t\n").len == 0) return error.MissingExec;

    var argv: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < exec.len and isSpace(exec[i])) i += 1;
        if (i >= exec.len) break;

        var arg: std.ArrayList(u8) = .empty;
        var quoted = false;
        var literal = false; // text or quotes besides field codes
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
                        if (ctx.targets.len > 0) try arg.appendSlice(arena, ctx.targets[0]);
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

        if (!literal and codes == 1 and (last_code == 'F' or last_code == 'U')) {
            for (ctx.targets) |t| try argv.append(arena, t);
        } else if (!literal and codes == 1 and last_code == 'i') {
            if (ctx.icon) |icon| {
                if (icon.len > 0) {
                    try argv.append(arena, "--icon");
                    try argv.append(arena, icon);
                }
            }
        } else if (!literal and codes > 0 and arg.items.len == 0) {
            // only field codes, and they expanded to nothing: drop the argument
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

fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

fn sameLocale(a: ?Locale, b: ?Locale) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x.same(y);
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return eql(u8, x, y);
}

fn decodeList(arena: Allocator, raw: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it: ListIterator = .{ .rest = raw };
    while (it.next()) |item| {
        try out.append(arena, try unescape(arena, item, true));
    }
    return out.items;
}

/// Resolves `\s \n \t \r \\`, and `\;` when `list_item` is set. Other escapes are
/// kept as written. Returns `raw` itself when there is nothing to resolve.
fn unescape(arena: Allocator, raw: []const u8, list_item: bool) Allocator.Error![]const u8 {
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
                ';' => if (list_item) ';' else null,
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

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (eql(u8, h, needle)) return true;
    }
    return false;
}

fn anyIn(haystack: []const []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (contains(haystack, n)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- demo

fn printOpt(out: *std.Io.Writer, label: []const u8, value: ?[]const u8) !void {
    if (value) |v| try out.print("{s: <13}{s}\n", .{ label, v });
}

fn printList(out: *std.Io.Writer, label: []const u8, items: []const []const u8) !void {
    if (items.len == 0) return;
    try out.print("{s: <13}", .{label});
    for (items, 0..) |item, i| {
        try out.print("{s}{s}", .{ if (i == 0) "" else ", ", item });
    }
    try out.print("\n", .{});
}

fn printArgv(out: *std.Io.Writer, label: []const u8, args: []const []const u8) !void {
    try out.print("{s: <13}", .{label});
    for (args) |a| try out.print("[{s}] ", .{a});
    try out.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: {s} <file.desktop> [locale]\n", .{args[0]});
        return;
    }
    const locale: ?[]const u8 = if (args.len > 2)
        args[2]
    else
        init.environ_map.get("LC_ALL") orelse init.environ_map.get("LC_MESSAGES") orelse init.environ_map.get("LANG");

    var desktops: std.ArrayList([]const u8) = .empty;
    if (init.environ_map.get("XDG_CURRENT_DESKTOP")) |v| {
        var it = std.mem.tokenizeScalar(u8, v, ':');
        while (it.next()) |d| try desktops.append(arena, d);
    }

    var doc = try parseFile(gpa, io, args[1], .{});
    defer doc.deinit();

    doc.validate() catch |err| {
        try out.print("invalid:     {s}\n", .{@errorName(err)});
    };

    const e = try doc.entry(locale);
    try out.print("{s: <13}{s}\n", .{ "Type", @tagName(e.kind) });
    try out.print("{s: <13}{s}\n", .{ "Name", e.name });
    try printOpt(out, "GenericName", e.generic_name);
    try printOpt(out, "Comment", e.comment);
    try printOpt(out, "Icon", e.icon);
    try printOpt(out, "Exec", e.exec);
    try printOpt(out, "TryExec", e.try_exec);
    try printOpt(out, "Path", e.path);
    try printOpt(out, "URL", e.url);
    try out.print("{s: <13}{}\n", .{ "Terminal", e.terminal });
    try printList(out, "Categories", e.categories);
    try printList(out, "MimeType", e.mime_types);
    try printList(out, "Keywords", e.keywords);
    try printList(out, "OnlyShowIn", e.only_show_in);
    try printList(out, "NotShowIn", e.not_show_in);
    try out.print("{s: <13}{}\n", .{ "In menu", e.showInMenu(desktops.items) });

    if (e.exec != null) {
        try printArgv(out, "argv", try e.argv(arena, .{}));
    }
    for (e.actions) |a| {
        try out.print("Action       {s}: {s}\n", .{ a.id, a.name });
        if (a.exec != null) try printArgv(out, "  argv", try a.argv(arena, .{}));
    }

    try out.flush();
}

// ---------------------------------------------------------------- tests

const sample =
    \\# A comment
    \\[Desktop Entry]
    \\Type=Application
    \\Version=1.5
    \\Name=Firefox
    \\Name[ar]=فايرفوكس
    \\Name[de_DE]=Feuerfuchs
    \\GenericName=Web Browser
    \\Comment = Browse\sthe\sWeb
    \\Icon=firefox
    \\Exec=firefox %u
    \\TryExec=firefox
    \\Terminal=false
    \\StartupNotify=true
    \\StartupWMClass=firefox
    \\Categories=Network;WebBrowser;
    \\MimeType=text/html;x-scheme-handler/http;
    \\Keywords=web;browser;
    \\Keywords[ar]=ويب;متصفح;
    \\OnlyShowIn=GNOME;KDE;
    \\Actions=new-window;private-window;
    \\X-Custom=hello
    \\
    \\[Desktop Action new-window]
    \\Name=New Window
    \\Exec=firefox --new-window %u
    \\
    \\[Desktop Action private-window]
    \\Name=New Private Window
    \\Icon=private
    \\Exec=firefox --private-window
    \\
;

const testing = std.testing;

test "groups, keys, comments and whitespace" {
    var doc = try parse(testing.allocator, sample, .{});
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 3), doc.groups.len);
    const g = doc.desktopEntry().?;
    try testing.expectEqualStrings("Firefox", g.get("Name").?);
    try testing.expectEqualStrings("Browse the Web", g.get("Comment").?);
    try testing.expectEqualStrings("hello", g.get("X-Custom").?);
    try testing.expect(g.get("Missing") == null);
    try testing.expectEqualStrings("firefox --private-window", doc.actionGroup("private-window").?.get("Exec").?);
}

test "BOM and CRLF" {
    var doc = try parse(testing.allocator, "\xEF\xBB\xBF[Desktop Entry]\r\nName=X\r\nExec=x\r\n", .{});
    defer doc.deinit();
    try testing.expectEqualStrings("X", doc.desktopEntry().?.get("Name").?);
    try testing.expectEqualStrings("x", doc.desktopEntry().?.get("Exec").?);
}

test "string escapes" {
    var doc = try parse(testing.allocator, "[G]\nA=one\\stwo\\nthree\\\\four\nB=keep\\;this\n", .{});
    defer doc.deinit();
    const g = doc.group("G").?;
    try testing.expectEqualStrings("one two\nthree\\four", g.get("A").?);
    try testing.expectEqualStrings("keep\\;this", g.get("B").?);
}

test "localized lookup with fallback" {
    var doc = try parse(testing.allocator,
        \\[Desktop Entry]
        \\Name=Plain
        \\Name[sr]=SR
        \\Name[sr@latin]=SR latin
        \\Name[sr_YU]=SR YU
        \\Name[sr_YU@latin]=SR YU latin
        \\Name[ar]=AR
    , .{});
    defer doc.deinit();
    const g = doc.desktopEntry().?;
    try testing.expectEqualStrings("SR YU latin", g.getLocalized("Name", "sr_YU.UTF-8@latin").?);
    try testing.expectEqualStrings("SR YU", g.getLocalized("Name", "sr_YU").?);
    try testing.expectEqualStrings("SR latin", g.getLocalized("Name", "sr@latin").?);
    try testing.expectEqualStrings("SR", g.getLocalized("Name", "sr_RS").?);
    try testing.expectEqualStrings("AR", g.getLocalized("Name", "ar_EG.UTF-8").?);
    try testing.expectEqualStrings("Plain", g.getLocalized("Name", "fr_FR").?);
    try testing.expectEqualStrings("Plain", g.getLocalized("Name", "C").?);
    try testing.expectEqualStrings("Plain", g.getLocalized("Name", "").?);
    try testing.expectEqualStrings("Plain", g.getLocalized("Name", null).?);
}

test "lists" {
    var doc = try parse(testing.allocator, "[Desktop Entry]\nKeywords= a ;b\\;c;d\\\\;;e\nEmpty=\n", .{});
    defer doc.deinit();
    const g = doc.desktopEntry().?;

    var it = g.getList("Keywords");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("b\\;c", it.next().?);
    try testing.expectEqualStrings("d\\\\", it.next().?);
    try testing.expectEqualStrings("e", it.next().?);
    try testing.expect(it.next() == null);

    const items = try g.getListAlloc(doc.arena.allocator(), "Keywords");
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("b;c", items[1]);
    try testing.expectEqualStrings("d\\", items[2]);

    var empty_it = g.getList("Empty");
    try testing.expect(empty_it.next() == null);
    var missing_it = g.getList("Missing");
    try testing.expect(missing_it.next() == null);
}

test "booleans and numbers" {
    var doc = try parse(testing.allocator, "[G]\nA=true\nB=False\nC=1\nD=maybe\nN=1.5\nM=abc\n", .{});
    defer doc.deinit();
    const g = doc.group("G").?;
    try testing.expectEqual(@as(?bool, true), g.getBool("A"));
    try testing.expectEqual(@as(?bool, false), g.getBool("B"));
    try testing.expectEqual(@as(?bool, true), g.getBool("C"));
    try testing.expectEqual(@as(?bool, null), g.getBool("D"));
    try testing.expectEqual(@as(?bool, null), g.getBool("Z"));
    try testing.expectEqual(@as(?f64, 1.5), g.getNumber("N"));
    try testing.expectEqual(@as(?f64, null), g.getNumber("M"));
}

test "typed entry" {
    var doc = try parse(testing.allocator, sample, .{});
    defer doc.deinit();

    const e = try doc.entry("ar_EG.UTF-8");
    try testing.expectEqual(Kind.application, e.kind);
    try testing.expectEqualStrings("1.5", e.version.?);
    try testing.expectEqualStrings("فايرفوكس", e.name);
    try testing.expectEqualStrings("Web Browser", e.generic_name.?);
    try testing.expectEqualStrings("Browse the Web", e.comment.?);
    try testing.expectEqualStrings("firefox", e.icon.?);
    try testing.expectEqualStrings("firefox %u", e.exec.?);
    try testing.expectEqualStrings("firefox", e.try_exec.?);
    try testing.expectEqual(false, e.terminal);
    try testing.expectEqual(@as(?bool, true), e.startup_notify);
    try testing.expectEqualStrings("firefox", e.startup_wm_class.?);
    try testing.expect(e.hasCategory("WebBrowser"));
    try testing.expect(!e.hasCategory("Games"));
    try testing.expect(e.hasMimeType("x-scheme-handler/http"));
    try testing.expectEqual(@as(usize, 2), e.keywords.len);
    try testing.expectEqualStrings("ويب", e.keywords[0]);
    try testing.expectEqualStrings("hello", e.group.get("X-Custom").?);

    try testing.expectEqual(@as(usize, 2), e.actions.len);
    try testing.expectEqualStrings("private-window", e.actions[1].id);
    try testing.expectEqualStrings("private", e.actions[1].icon.?);
    try testing.expectEqualStrings("New Window", e.action("new-window").?.name);
    try testing.expect(e.action("nope") == null);

    const en = try doc.entry("en_US.UTF-8");
    try testing.expectEqualStrings("Firefox", en.name);
    try testing.expectEqualStrings("web", en.keywords[0]);
}

test "showInMenu" {
    var doc = try parse(testing.allocator, sample, .{});
    defer doc.deinit();
    const e = try doc.entry(null);

    const gnome = [_][]const u8{"GNOME"};
    const xfce_gnome = [_][]const u8{ "XFCE", "GNOME" };
    const xfce = [_][]const u8{"XFCE"};
    try testing.expect(e.showInMenu(&gnome));
    try testing.expect(e.showInMenu(&xfce_gnome));
    try testing.expect(!e.showInMenu(&xfce));
    try testing.expect(!e.showInMenu(&.{}));

    var doc2 = try parse(testing.allocator, "[Desktop Entry]\nNotShowIn=KDE;\n", .{});
    defer doc2.deinit();
    const kde = [_][]const u8{"KDE"};
    try testing.expect((try doc2.entry(null)).showInMenu(&gnome));
    try testing.expect(!(try doc2.entry(null)).showInMenu(&kde));

    var doc3 = try parse(testing.allocator, "[Desktop Entry]\nNoDisplay=true\n", .{});
    defer doc3.deinit();
    try testing.expect(!(try doc3.entry(null)).showInMenu(&gnome));

    var doc4 = try parse(testing.allocator, "[Desktop Entry]\nHidden=true\n", .{});
    defer doc4.deinit();
    try testing.expect(!(try doc4.entry(null)).showInMenu(&gnome));
}

test "validate" {
    var ok = try parse(testing.allocator, sample, .{});
    defer ok.deinit();
    try ok.validate();

    const cases = [_]struct { src: []const u8, err: ValidationError }{
        .{ .src = "[Other]\nName=x\n", .err = error.MissingDesktopEntryGroup },
        .{ .src = "[Other]\n[Desktop Entry]\nType=Application\nName=x\nExec=x\n", .err = error.MissingDesktopEntryGroup },
        .{ .src = "[Desktop Entry]\nName=x\n", .err = error.MissingType },
        .{ .src = "[Desktop Entry]\nType=Application\n", .err = error.MissingName },
        .{ .src = "[Desktop Entry]\nType=Application\nName=x\n", .err = error.MissingExec },
        .{ .src = "[Desktop Entry]\nType=Link\nName=x\n", .err = error.MissingUrl },
        .{ .src = "[Desktop Entry]\nType=Application\nName=x\nExec=x\nTerminal=yes\n", .err = error.InvalidBoolean },
        .{ .src = "[Desktop Entry]\nType=Application\nName=x\nExec=x\nNoDisplay=True\n", .err = error.InvalidBoolean },
        .{ .src = "[Desktop Entry]\nType=Application\nName=x\nExec=x\nActions=a;\n", .err = error.MissingActionGroup },
    };
    for (cases) |c| {
        var doc = try parse(testing.allocator, c.src, .{});
        defer doc.deinit();
        try testing.expectError(c.err, doc.validate());
    }

    var dbus = try parse(testing.allocator, "[Desktop Entry]\nType=Application\nName=x\nDBusActivatable=true\n", .{});
    defer dbus.deinit();
    try dbus.validate();

    var dir = try parse(testing.allocator, "[Desktop Entry]\nType=Directory\nName=x\n", .{});
    defer dir.deinit();
    try dir.validate();
}

test "lenient parsing skips what it cannot read" {
    var doc = try parse(testing.allocator,
        \\stray=1
        \\[Desktop Entry]
        \\Name=Real
        \\garbage line
        \\Bad_Key=1
        \\Name[]=empty
        \\[Desktop Action broken
        \\Name=Impostor
        \\[Other]
        \\Name=Other
    , .{});
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.groups.len);
    try testing.expectEqualStrings("Real", doc.desktopEntry().?.get("Name").?);
    try testing.expect(doc.desktopEntry().?.get("Bad_Key") == null);
    try testing.expectEqualStrings("Other", doc.group("Other").?.get("Name").?);
}

test "duplicates: last key wins, first group wins" {
    var doc = try parse(testing.allocator, "[G]\nName=a\nName=b\n[G]\nName=c\n", .{});
    defer doc.deinit();
    try testing.expectEqualStrings("b", doc.group("G").?.get("Name").?);
}

test "strict parsing reports problems" {
    const strict: Options = .{ .strict = true };
    try testing.expectError(error.EntryOutsideGroup, parse(testing.allocator, "Name=Foo\n", strict));
    try testing.expectError(error.InvalidLine, parse(testing.allocator, "[Desktop Entry]\nnot a pair\n", strict));
    try testing.expectError(error.InvalidGroupHeader, parse(testing.allocator, "[Desktop Entry\n", strict));
    try testing.expectError(error.InvalidKey, parse(testing.allocator, "[Desktop Entry]\nBad_Key=1\n", strict));
    try testing.expectError(error.InvalidKey, parse(testing.allocator, "[Desktop Entry]\nName[]=1\n", strict));
    try testing.expectError(error.DuplicateKey, parse(testing.allocator, "[Desktop Entry]\nName=a\nName=b\n", strict));
    try testing.expectError(error.DuplicateGroup, parse(testing.allocator, "[A]\n[A]\n", strict));

    // different locales are not duplicates
    var doc = try parse(testing.allocator, "[A]\nName=a\nName[de]=b\n", strict);
    doc.deinit();
}

fn expectArgv(exec: []const u8, ctx: ExecContext, expected: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const got = try expandExec(arena_state.allocator(), exec, ctx);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try testing.expectEqualStrings(want, have);
}

test "exec: plain arguments and single targets" {
    try expectArgv("firefox %u", .{ .targets = &.{"https://a.org"} }, &.{ "firefox", "https://a.org" });
    try expectArgv("firefox %u", .{}, &.{"firefox"});
    try expectArgv("  prog   -x\t-y ", .{}, &.{ "prog", "-x", "-y" });
    try expectArgv("prog --file=%f", .{ .targets = &.{"x"} }, &.{ "prog", "--file=x" });
    try expectArgv("prog --file=%f", .{}, &.{ "prog", "--file=" });
}

test "exec: list codes" {
    try expectArgv("vlc %F", .{ .targets = &.{ "a", "b" } }, &.{ "vlc", "a", "b" });
    try expectArgv("vlc %U --end", .{ .targets = &.{ "a", "b" } }, &.{ "vlc", "a", "b", "--end" });
    try expectArgv("vlc %F", .{}, &.{"vlc"});
    try expectArgv("vlc --list=%F", .{ .targets = &.{ "a", "b" } }, &.{ "vlc", "--list=a" });
}

test "exec: icon, name, location, percent, deprecated" {
    const ctx: ExecContext = .{ .icon = "ic", .name = "My App", .location = "/x.desktop" };
    try expectArgv("app %i %c %k", ctx, &.{ "app", "--icon", "ic", "My App", "/x.desktop" });
    try expectArgv("app %i", .{}, &.{"app"});
    try expectArgv("app 100%% %d %D %n %N %v %m", .{}, &.{ "app", "100%" });
}

test "exec: quoting" {
    try expectArgv("sh -c \"echo \\\"hi\\\" 100%%\"", .{}, &.{ "sh", "-c", "echo \"hi\" 100%" });
    try expectArgv("sh -c \"a  b\" \"\"", .{}, &.{ "sh", "-c", "a  b", "" });
    try expectArgv("env A=\"x y\" prog", .{}, &.{ "env", "A=x y", "prog" });
    try expectArgv("prog \"\\$HOME `x` \\\\ \\q\"", .{}, &.{ "prog", "$HOME `x` \\ \\q" });
}

test "exec: errors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectError(error.UnterminatedQuote, expandExec(a, "prog \"open", .{}));
    try testing.expectError(error.InvalidFieldCode, expandExec(a, "prog %z", .{}));
    try testing.expectError(error.InvalidFieldCode, expandExec(a, "prog %", .{}));
    try testing.expectError(error.MissingExec, expandExec(a, "   ", .{}));
}

test "exec: both escape layers from a real file" {
    var doc = try parse(testing.allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=X
        \\Exec=prog "a\\\\b" %f
    , .{});
    defer doc.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const e = try doc.entry(null);
    const got = try e.argv(arena_state.allocator(), .{ .targets = &.{"/tmp/f"} });
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("a\\b", got[1]);
    try testing.expectEqualStrings("/tmp/f", got[2]);
}

test "entry argv and action argv" {
    var doc = try parse(testing.allocator, sample, .{});
    defer doc.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const e = try doc.entry(null);
    const main_argv = try e.argv(a, .{ .targets = &.{"https://a.org"} });
    try testing.expectEqualStrings("https://a.org", main_argv[1]);

    const act = try e.action("new-window").?.argv(a, .{ .targets = &.{"https://b.org"} });
    try testing.expectEqual(@as(usize, 3), act.len);
    try testing.expectEqualStrings("--new-window", act[1]);

    var no_exec = try parse(testing.allocator, "[Desktop Entry]\nName=x\n", .{});
    defer no_exec.deinit();
    try testing.expectError(error.MissingExec, (try no_exec.entry(null)).argv(a, .{}));
}

test "desktop file id" {
    const id = try desktopFileId(testing.allocator, "kde/foo.desktop");
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("kde-foo.desktop", id);
}

test "missing [Desktop Entry] group" {
    var doc = try parse(testing.allocator, "[Other]\nName=x\n", .{});
    defer doc.deinit();
    try testing.expectError(error.MissingDesktopEntryGroup, doc.entry(null));
}
