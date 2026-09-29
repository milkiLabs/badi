const std = @import("std");

/// Parsed representation of a freedesktop.org `.desktop` file's
/// `[Desktop Entry]` group.
///
/// All string slices borrow from the input buffer passed to `parse`,
/// so the input must outlive the returned struct. Use `dupe` to get
/// an owned copy when needed.
pub const DesktopEntry = struct {
    entry_type: []const u8 = "",
    version: []const u8 = "",
    name: []const u8 = "",
    comment: []const u8 = "",
    path: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    terminal: bool = false,
    /// Raw `Categories` value, e.g. `"Education;Languages;Java;"`.
    /// Use `categoryIterator` / `hasCategory` to inspect individual entries.
    categories: []const u8 = "",

    /// Deep-copy all fields using `allocator`. Caller owns the result.
    pub fn dupe(self: DesktopEntry, allocator: std.mem.Allocator) !DesktopEntry {
        var out = self;
        inline for (&.{ "entry_type", "version", "name", "comment", "path", "exec", "icon", "categories" }) |field| {
            @field(out, field) = try allocator.dupe(u8, @field(self, field));
        }
        return out;
    }

    pub fn free(self: *DesktopEntry, allocator: std.mem.Allocator) void {
        inline for (&.{ "entry_type", "version", "name", "comment", "path", "exec", "icon", "categories" }) |field| {
            allocator.free(@field(self.*, field));
            @field(self.*, field) = "";
        }
    }

    /// Iterate over `;`-separated categories, skipping empties
    /// (the spec mandates a trailing `;`).
    pub fn categoryIterator(self: DesktopEntry) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, self.categories, ';');
    }

    /// Case-sensitive membership test, e.g. `entry.hasCategory("Education")`.
    pub fn hasCategory(self: DesktopEntry, wanted: []const u8) bool {
        var it = self.categoryIterator();
        while (it.next()) |cat| {
            const trimmed = std.mem.trim(u8, cat, " \t");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, wanted)) return true;
        }
        return false;
    }
};

pub const ParseError = error{
    InvalidTerminalValue,
};

/// Parse the `[Desktop Entry]` group of a `.desktop` file.
///
/// Rules:
///   * Blank lines, `#` comments, and `[Group]` headers are skipped.
///   * Only keys inside `[Desktop Entry]` are collected. If the input
///     has no group header at all, keys are still parsed leniently.
///   * `Key=Value` splits on the first `=`; surrounding whitespace is trimmed.
///   * Unknown keys (including localized `Name[fr]=...`) are ignored.
///   * `Terminal` accepts `true`/`false` (case-insensitive) plus `1`/`0`.
///   * Last occurrence of a duplicated key wins.
pub fn parse(input: []const u8) ParseError!DesktopEntry {
    var entry: DesktopEntry = .{};
    var in_desktop_entry = true; // lenient until we see a header
    var saw_any_header = false;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        // skip blank lines and comments
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Group header: [Desktop Entry], [Desktop Action Foo], ...
        if (line[0] == '[') {
            if (line[line.len - 1] == ']') {
                saw_any_header = true;
                const group = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
                in_desktop_entry = std.mem.eql(u8, group, "Desktop Entry");
                continue;
            }
            continue; // malformed header: ignore line
        }

        if (saw_any_header and !in_desktop_entry) continue;

        // Parse key=value, trimming whitespace. Ignore lines without '='.
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "Type")) {
            entry.entry_type = value;
        } else if (std.mem.eql(u8, key, "Version")) {
            entry.version = value;
        } else if (std.mem.eql(u8, key, "Name")) {
            entry.name = value;
        } else if (std.mem.eql(u8, key, "Comment")) {
            entry.comment = value;
        } else if (std.mem.eql(u8, key, "Path")) {
            entry.path = value;
        } else if (std.mem.eql(u8, key, "Exec")) {
            entry.exec = value;
        } else if (std.mem.eql(u8, key, "Icon")) {
            entry.icon = value;
        } else if (std.mem.eql(u8, key, "Terminal")) {
            if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) {
                entry.terminal = true;
            } else if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) {
                entry.terminal = false;
            } else {
                return error.InvalidTerminalValue;
            }
        } else if (std.mem.eql(u8, key, "Categories")) {
            entry.categories = value;
        }
        // else: unknown / localized key -> ignore
    }

    return entry;
}

const sample_desktop_file =
    \\[Desktop Entry]
    \\# The type as listed above
    \\Type=Application
    \\
    \\# The version of the desktop entry specification to which this file conforms
    \\Version=1.0
    \\
    \\# The name of the application
    \\Name=jMemorize
    \\
    \\# A comment which can/will be used as a tooltip
    \\Comment=Flash card based learning tool
    \\
    \\# The path to the folder in which the executable is run
    \\Path=/opt/jmemorise
    \\
    \\# The executable of the application, possibly with arguments.
    \\Exec=jmemorize
    \\
    \\# The name of the icon that will be used to display this entry
    \\Icon=jmemorize
    \\
    \\# Describes whether this application needs to be run in a terminal or not
    \\Terminal=false
    \\
    \\# Describes the categories in which this entry should be shown
    \\Categories=Education;Languages;Java;
;

fn printEntry(entry: DesktopEntry, writer: *std.Io.Writer) !void {
    try writer.print("Type: {s}\n", .{entry.entry_type});
    try writer.print("Version: {s}\n", .{entry.version});
    try writer.print("Name: {s}\n", .{entry.name});
    try writer.print("Comment: {s}\n", .{entry.comment});
    try writer.print("Path: {s}\n", .{entry.path});
    try writer.print("Exec: {s}\n", .{entry.exec});
    try writer.print("Icon: {s}\n", .{entry.icon});
    try writer.print("Terminal: {}\n", .{entry.terminal});
    try writer.print("Categories: {s}\n", .{entry.categories});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Optional argv[1]: path to a .desktop file. Otherwise parse the sample.
    const args = try init.minimal.args.toSlice(arena);
    const input: []const u8 = if (args.len > 1)
        try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20))
    else
        sample_desktop_file;

    const entry = try parse(input);
    try printEntry(entry, stdout);
    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests: `zig test src/main.zig`
// ---------------------------------------------------------------------------

test "parses the jMemorize example" {
    const entry = try parse(sample_desktop_file);
    try std.testing.expectEqualStrings("Application", entry.entry_type);
    try std.testing.expectEqualStrings("1.0", entry.version);
    try std.testing.expectEqualStrings("jMemorize", entry.name);
    try std.testing.expectEqualStrings("Flash card based learning tool", entry.comment);
    try std.testing.expectEqualStrings("/opt/jmemorise", entry.path);
    try std.testing.expectEqualStrings("jmemorize", entry.exec);
    try std.testing.expectEqualStrings("jmemorize", entry.icon);
    try std.testing.expectEqual(false, entry.terminal);
    try std.testing.expectEqualStrings("Education;Languages;Java;", entry.categories);
    try std.testing.expect(entry.hasCategory("Education"));
    try std.testing.expect(entry.hasCategory("Languages"));
    try std.testing.expect(entry.hasCategory("Java"));
    try std.testing.expect(!entry.hasCategory("Games"));
}

test "comments, blanks, and whitespace are ignored" {
    const entry = try parse(
        \\# leading comment
        \\   # indented comment
        \\
        \\[Desktop Entry]
        \\  Name  =  spaced
        \\Exec=foo=bar  # value keeps everything after first '='
    );
    try std.testing.expectEqualStrings("spaced", entry.name);
    try std.testing.expectEqualStrings("foo=bar  # value keeps everything after first '='", entry.exec);
}

test "terminal accepts true/false/1/0, rejects garbage" {
    try std.testing.expectEqual(true, (try parse("[Desktop Entry]\nTerminal=true\n")).terminal);
    try std.testing.expectEqual(true, (try parse("[Desktop Entry]\nTerminal=TRUE\n")).terminal);
    try std.testing.expectEqual(true, (try parse("[Desktop Entry]\nTerminal=1\n")).terminal);
    try std.testing.expectEqual(false, (try parse("[Desktop Entry]\nTerminal=false\n")).terminal);
    try std.testing.expectEqual(false, (try parse("[Desktop Entry]\nTerminal=0\n")).terminal);
    try std.testing.expectError(error.InvalidTerminalValue, parse("[Desktop Entry]\nTerminal=yes\n"));
}

test "keys outside [Desktop Entry] are ignored, last wins" {
    const entry = try parse(
        \\[Desktop Entry]
        \\Name=first
        \\Name=second
        \\[Desktop Action New]
        \\Name=should-be-ignored
        \\Exec=ignored
    );
    try std.testing.expectEqualStrings("second", entry.name);
    try std.testing.expectEqualStrings("", entry.exec);
}

test "unknown and localized keys are ignored" {
    const entry = try parse(
        \\[Desktop Entry]
        \\Name=app
        \\Name[fr]=appli
        \\X-Custom=whatever
    );
    try std.testing.expectEqualStrings("app", entry.name);
}
