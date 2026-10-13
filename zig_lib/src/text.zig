//! Small string helpers shared by the parser, Exec expansion, and search.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// Resolve `\s \n \t \r \\`. Other escapes are kept as written.
/// Returns `raw` itself when there is nothing to resolve.
pub fn unescape(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
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

/// Lowercase ASCII copy. Non-ASCII bytes pass through untouched.
pub fn lowerDup(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// ASCII case-insensitive `<` for byte strings (sort order).
pub fn asciiLessThan(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return lx < ly;
    }
    return a.len < b.len;
}
