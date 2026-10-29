//! Asynchronous line input for frontends that need to consume piped stdin
//! without blocking their event loop. Lines are grouped by size or idle time
//! and delivered as newline-delimited UTF-8 bytes in an owned buffer.

const std = @import("std");
const linux = std.os.linux;

const allocator = std.heap.c_allocator;

pub const Callback = *const fn (
    context: ?*anyopaque,
    batch: [*:0]const u8,
    byte_len: usize,
    line_count: usize,
    event: c_int,
) callconv(.c) void;

const batch_limit = 500;
const idle_ms = 100;
const read_size = 16 * 1024;

const State = struct {
    callback: Callback,
    context: ?*anyopaque,
    bytes: std.ArrayList(u8) = .empty,
    lines: usize = 0,
    line: std.ArrayList(u8) = .empty,
};

var started = std.atomic.Value(bool).init(false);

/// Start the single process-wide stdin reader. `event` is 0 for data, 1 for
/// EOF, and -1 for a read error. Data pointers remain valid until the
/// frontend calls `badi_stdin_batch_free`.
pub fn start(callback: Callback, context: ?*anyopaque) bool {
    if (started.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return false;

    const state = allocator.create(State) catch {
        started.store(false, .release);
        return false;
    };
    state.* = .{ .callback = callback, .context = context };
    _ = std.Thread.spawn(.{}, readThread, .{state}) catch {
        allocator.destroy(state);
        started.store(false, .release);
        return false;
    };
    return true;
}

fn readThread(state: *State) void {
    var buffer: [read_size]u8 = undefined;
    var poll_fd = linux.pollfd{ .fd = 0, .events = linux.POLL.IN, .revents = 0 };
    var pending_cr = false;
    var error_code: c_int = 1;

    while (true) {
        poll_fd.revents = 0;
        const ready = linux.poll((&poll_fd)[0..1].ptr, 1, idle_ms);
        const poll_error = linux.errno(ready);
        if (poll_error != .SUCCESS) {
            if (poll_error == .INTR) continue;
            error_code = -1;
            break;
        }
        if (ready == 0) {
            flush(state, 0);
            continue;
        }

        const count = linux.read(0, &buffer, buffer.len);
        const read_error = linux.errno(count);
        if (read_error != .SUCCESS) {
            if (read_error == .INTR) continue;
            error_code = -1;
            break;
        }
        if (count == 0) break;

        for (buffer[0..count]) |byte| {
            if (pending_cr) {
                appendLineAndFlush(state) catch {
                    error_code = -1;
                    break;
                };
                pending_cr = false;
                if (byte == '\n') continue;
            }

            if (byte == '\r') {
                pending_cr = true;
            } else if (byte == '\n') {
                appendLineAndFlush(state) catch {
                    error_code = -1;
                    break;
                };
            } else {
                state.line.append(allocator, byte) catch {
                    error_code = -1;
                    break;
                };
            }
        }
        if (error_code < 0) break;
    }

    // Match LineSplitter: emit a final unterminated line at EOF, and ignore
    // blank lines as the Flutter stdin path did before moving here.
    if (pending_cr or state.line.items.len > 0) appendLine(state) catch {
        error_code = -1;
    };
    flush(state, 0);
    state.callback(state.context, "", 0, 0, error_code);
    state.bytes.deinit(allocator);
    state.line.deinit(allocator);
    allocator.destroy(state);
}

fn appendLine(state: *State) !void {
    if (state.line.items.len != 0) {
        try state.bytes.appendSlice(allocator, state.line.items);
        try state.bytes.append(allocator, '\n');
        state.lines += 1;
    }
    state.line.clearRetainingCapacity();
}

fn appendLineAndFlush(state: *State) !void {
    try appendLine(state);
    if (state.lines >= batch_limit) flush(state, 0);
}

fn flush(state: *State, event: c_int) void {
    if (state.lines == 0) return;
    const owned = state.bytes.toOwnedSliceSentinel(allocator, 0) catch return;
    state.callback(state.context, owned.ptr, owned.len, state.lines, event);
    state.bytes = .empty;
    state.lines = 0;
}
