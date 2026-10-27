//! CPU + memory snapshots from /proc. Pure parsing lives here so it is
//! unit-testable; thin FFI wrappers live in `ffi.zig`.
//!
//! Design: stateless snapshots. Dart polls on a Timer, keeps the previous
//! CPU sample, and derives utilization with `cpuUsageBetween`. No threads,
//! no timers, no allocation across the FFI boundary.

const std = @import("std");

/// Raw CPU counters from the aggregate `cpu ...` line in /proc/stat.
/// `total` is the sum of all fields, `idle` is idle+iowait.
pub const CpuSnapshot = extern struct {
    total: u64,
    idle: u64,
};

/// Memory totals in bytes plus a derived used fraction 0..1.
pub const MemInfo = extern struct {
    total_bytes: u64,
    avail_bytes: u64,
    used_percent: f64,
};

const max_proc_size = 1 << 16; // /proc files are tiny; 64KiB is plenty

/// Read a (possibly virtual, e.g. /proc) file into `buf` via streaming.
/// `readFileAlloc` cannot be used here: procfs reports size 0, so it
/// returns an empty slice. Returns the bytes read.
fn readProc(io: std.Io, path: []const u8, buf: []u8) ?[]u8 {
    return std.Io.Dir.cwd().readFile(io, path, buf) catch null;
}

/// Parse the aggregate `cpu ...` line out of /proc/stat content.
/// Needs at least user/nice/system/idle; returns null when missing.
pub fn parseCpuStat(content: []const u8) ?CpuSnapshot {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu ")) continue;
        var it = std.mem.tokenizeAny(u8, line[3..], " \t");
        var fields: [10]u64 = undefined;
        var n: usize = 0;
        while (it.next()) |tok| {
            if (n >= fields.len) break;
            fields[n] = std.fmt.parseInt(u64, tok, 10) catch return null;
            n += 1;
        }
        if (n < 4) return null;
        var total: u64 = 0;
        for (fields[0..n]) |v| total +|= v;
        const idle = fields[3] +| (if (n > 4) fields[4] else 0);
        return .{ .total = total, .idle = idle };
    }
    return null;
}

/// Utilization fraction 0..1 between two snapshots. Returns -1 when the
/// pair is invalid (zero delta, counters went backwards).
pub fn cpuUsageBetween(prev: CpuSnapshot, cur: CpuSnapshot) f64 {
    if (cur.total < prev.total or cur.idle < prev.idle) return -1;
    const total_delta = cur.total - prev.total;
    if (total_delta == 0) return -1;
    const idle_delta = cur.idle - prev.idle;
    if (idle_delta > total_delta) return -1;
    const used = @as(f64, @floatFromInt(total_delta - idle_delta)) /
        @as(f64, @floatFromInt(total_delta));
    return @min(1.0, @max(0.0, used));
}

fn valueAfter(line: []const u8, prefix: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var tok = std.mem.tokenizeAny(u8, line[prefix.len..], " \t");
    const num = tok.next() orelse return null;
    return std.fmt.parseInt(u64, num, 10) catch null;
}

pub fn parseMeminfo(content: []const u8) ?MemInfo {
    var total_kb: ?u64 = null;
    var avail_kb: ?u64 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (valueAfter(line, "MemTotal:")) |v| {
            total_kb = v;
        } else if (valueAfter(line, "MemAvailable:")) |v| {
            avail_kb = v;
        }
        if (total_kb != null and avail_kb != null) break;
    }

    const total = total_kb orelse return null;
    const avail = avail_kb orelse return null;

    return .{
        .total_bytes = total * 1024,
        .avail_bytes = avail * 1024,
        .used_percent = @as(f64, @floatFromInt(total - avail)) /
            @as(f64, @floatFromInt(total)),
    };
}

pub fn readMeminfo(io: std.Io) !MemInfo {
    const file = try std.Io.Dir.cwd().openFile(io, "/proc/meminfo", .{});
    defer file.close(io);

    var buf: [512]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    return parseMeminfo(buf[0..n]) orelse error.InvalidMeminfo;
}

/// Fill `out` with current memory info. False on read/parse failure.
pub fn snapshotMem(out: *MemInfo) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    out.* = readMeminfo(io) catch return false;
    return true;
}

/// Fill `out` with the current CPU counters. False on read/parse failure.
pub fn snapshotCpu(out: *CpuSnapshot) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [max_proc_size]u8 = undefined;
    const src = readProc(io, "/proc/stat", &buf) orelse return false;
    const s = parseCpuStat(src) orelse return false;
    out.* = s;
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "parse cpu aggregate line" {
    const s = parseCpuStat("cpu  100 20 30 400 50 0 10 0 0 0\ncpu0 50 10 15 200 25 0 5 0 0 0\n").?;
    try testing.expectEqual(@as(u64, 100 + 20 + 30 + 400 + 50 + 0 + 10), s.total);
    try testing.expectEqual(@as(u64, 400 + 50), s.idle);
}

test "parse cpu needs 4 fields" {
    try testing.expect(parseCpuStat("cpu  1 2\n") == null);
    try testing.expect(parseCpuStat("intr 123\n") == null);
}

test "cpu usage is idle delta over total delta" {
    const prev = CpuSnapshot{ .total = 1000, .idle = 800 };
    const cur = CpuSnapshot{ .total = 1100, .idle = 820 };
    // total_delta=100, idle_delta=20 -> 0.8 busy
    try testing.expectApproxEqAbs(@as(f64, 0.8), cpuUsageBetween(prev, cur), 1e-9);
}

test "cpu usage rejects bad pairs" {
    const a = CpuSnapshot{ .total = 1000, .idle = 800 };
    try testing.expectEqual(@as(f64, -1), cpuUsageBetween(a, a)); // zero delta
    try testing.expectEqual(@as(f64, -1), cpuUsageBetween(.{ .total = 2000, .idle = 800 }, a)); // backwards
}

test "parse meminfo with MemAvailable" {
    const m = parseMeminfo("MemTotal:        8000000 kB\nMemFree:          100000 kB\nMemAvailable:    4000000 kB\nBuffers:           50000 kB\nCached:          2000000 kB\n").?;
    try testing.expectEqual(@as(u64, 8000000 * 1024), m.total_bytes);
    try testing.expectEqual(@as(u64, 4000000 * 1024), m.avail_bytes);
    try testing.expectApproxEqAbs(@as(f64, 0.5), m.used_percent, 1e-9);
}
