//! Download-rate sampling from the Linux default-route interface.
//! Parsing, counter tracking, and rate calculation stay on the Zig side;
//! the FFI returns bytes per second or -1 when a sample is unavailable.

const std = @import("std");
const linux = std.os.linux;

const max_proc_size = 1 << 16;

const SampleState = struct {
    interface: [16]u8 = undefined,
    interface_len: usize = 0,
    rx_bytes: ?u64 = null,
    monotonic_ns: ?u64 = null,
};

var previous_sample: SampleState = .{};

fn readFile(io: std.Io, path: []const u8, buf: []u8) ?[]u8 {
    return std.Io.Dir.cwd().readFile(io, path, buf) catch null;
}

/// Select the lowest-metric active IPv4 default route from /proc/net/route.
pub fn parseDefaultRoute(content: []const u8) ?[]const u8 {
    var selected: ?[]const u8 = null;
    var selected_metric: u32 = std.math.maxInt(u32);
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const iface = fields.next() orelse continue;
        const destination = fields.next() orelse continue;
        const gateway = fields.next() orelse continue;
        const flags_text = fields.next() orelse continue;
        _ = gateway;
        _ = fields.next() orelse continue; // ref count
        _ = fields.next() orelse continue; // use
        const metric_text = fields.next() orelse continue;
        if (!std.mem.eql(u8, destination, "00000000")) continue;
        const flags = std.fmt.parseInt(u32, flags_text, 16) catch continue;
        if ((flags & 1) == 0) continue; // RTF_UP
        const metric = std.fmt.parseInt(u32, metric_text, 10) catch continue;
        if (metric < selected_metric) {
            selected = iface;
            selected_metric = metric;
        }
    }
    return selected;
}

/// Read the current received-byte counter on the active default route,
/// then calculate the byte rate since the previous call.
/// Returns -1 until two valid samples exist or when the interface is down.
pub fn snapshotDownloadBytesPerSecond() f64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var routes_buf: [max_proc_size]u8 = undefined;
    const routes = readFile(io, "/proc/net/route", &routes_buf) orelse {
        previous_sample = .{};
        return -1;
    };
    const iface = parseDefaultRoute(routes) orelse {
        previous_sample = .{};
        return -1;
    };

    var counter_path: [128]u8 = undefined;
    const path = std.fmt.bufPrint(
        &counter_path,
        "/sys/class/net/{s}/statistics/rx_bytes",
        .{iface},
    ) catch {
        previous_sample = .{};
        return -1;
    };
    var counter_buf: [64]u8 = undefined;
    const counter_text = readFile(io, path, &counter_buf) orelse {
        previous_sample = .{};
        return -1;
    };
    const rx_bytes = std.fmt.parseInt(u64, std.mem.trim(u8, counter_text, " \t\r\n"), 10) catch {
        previous_sample = .{};
        return -1;
    };

    var now: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &now) != 0 or now.sec < 0 or now.nsec < 0) {
        previous_sample = .{};
        return -1;
    }
    const now_ns = @as(u64, @intCast(now.sec)) * 1_000_000_000 +
        @as(u64, @intCast(now.nsec));

    const same_interface = previous_sample.interface_len == iface.len and
        std.mem.eql(u8, previous_sample.interface[0..previous_sample.interface_len], iface);
    const result: f64 = if (same_interface) blk: {
        const old_bytes = previous_sample.rx_bytes orelse break :blk -1;
        const old_ns = previous_sample.monotonic_ns orelse break :blk -1;
        if (rx_bytes < old_bytes or now_ns <= old_ns) break :blk -1;
        const elapsed_ns = now_ns - old_ns;
        break :blk @as(f64, @floatFromInt(rx_bytes - old_bytes)) *
            1_000_000_000 / @as(f64, @floatFromInt(elapsed_ns));
    } else -1;

    if (iface.len > previous_sample.interface.len) {
        previous_sample = .{};
        return -1;
    }
    @memcpy(previous_sample.interface[0..iface.len], iface);
    previous_sample.interface_len = iface.len;
    previous_sample.rx_bytes = rx_bytes;
    previous_sample.monotonic_ns = now_ns;
    return result;
}
