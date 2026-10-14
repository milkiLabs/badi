//! `Exec` → argv: quoting and `%` field-code expansion for a bare launch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");

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
        while (i < exec.len and text.isSpace(exec[i])) i += 1;
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
            } else if (text.isSpace(c)) {
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

// ---------------------------------------------------------------- tests

const testing = std.testing;

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
