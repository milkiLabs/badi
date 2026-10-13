//! C ABI for the picker core: stateful sessions over scanned apps or piped
//! input lines. Dart/Flutter renders rows and owns stdin/stdout; all
//! filtering, selection, and launching lives here.
//!
//! `zig_lib.h` is the source of truth for ffigen; keep the signatures in sync.
//!
//! Ownership:
//! - `badi_session_apps`/`badi_session_lines` return a heap-owned handle,
//!   free with `badi_session_destroy`.
//! - Every getter returns a heap-owned NUL-terminated copy (or NULL when
//!   missing), free with `badi_free_string`.
//! - All functions are null-tolerant and never panic across the FFI boundary.

const std = @import("std");
const session = @import("session.zig");

const c_alloc = std.heap.c_allocator;

/// Opaque handle owning a picker session. ABI-identical to
/// `struct BadiSession` in `zig_lib.h`.
pub const BadiSession = opaque {};

const Box = struct {
    s: session.Session,
};

/// Free a string from any getter. NULL-safe.
export fn badi_free_string(s: ?[*:0]u8) callconv(.c) void {
    if (s == null) return;
    c_alloc.free(std.mem.span(s.?));
}

/// Open an apps-mode session: scan system + user `applications` dirs,
/// sorted by name. `locale` (NULL = unlocalized) picks localized
/// Name/Icon/Comment. Returns NULL only on OOM.
/// Free with `badi_session_destroy`.
///
/// Uses a single-threaded Io instance internally; sequential calls are fine,
/// concurrent calls from multiple threads are not supported.
export fn badi_session_apps(locale: ?[*:0]const u8) callconv(.c) ?*BadiSession {
    const lang: ?[]const u8 = if (locale) |l| std.mem.span(l) else null;
    const io = std.Io.Threaded.global_single_threaded.io();
    const box = c_alloc.create(Box) catch return null;
    box.s = session.Session.initApps(c_alloc, io, lang) catch {
        c_alloc.destroy(box);
        return null;
    };
    return @ptrCast(box);
}

/// Open a lines-mode session over `lines` (copied; caller keeps ownership).
/// NULL lines or 0 count opens an empty session. Returns NULL only on OOM.
/// Free with `badi_session_destroy`.
export fn badi_session_lines(lines: ?[*]const [*:0]const u8, n: usize) callconv(.c) ?*BadiSession {
    const box = c_alloc.create(Box) catch return null;
    errdefer c_alloc.destroy(box);
    if (lines) |ls| {
        if (n > 0) {
            const buf = c_alloc.alloc([]const u8, n) catch return null;
            defer c_alloc.free(buf);
            for (buf, 0..) |*slot, i| slot.* = std.mem.span(ls[i]);
            box.s = session.Session.initLines(c_alloc, buf) catch return null;
            return @ptrCast(box);
        }
    }
    box.s = session.Session.initLines(c_alloc, &.{}) catch return null;
    return @ptrCast(box);
}

/// Re-filter on `query` (NULL/blank shows all, ASCII case-insensitive
/// substring) and reset selection to the top. Returns 0, -1 on bad handle
/// or OOM (previous view is kept on OOM).
export fn badi_session_query(handle: ?*BadiSession, query: ?[*:0]const u8) callconv(.c) c_int {
    const s = sessionOf(handle) orelse return -1;
    const q: ?[]const u8 = if (query) |x| std.mem.span(x) else null;
    s.setQuery(q) catch return -1;
    return 0;
}

/// Shown row count. NULL-safe (NULL handle = 0).
export fn badi_session_count(handle: ?*const BadiSession) callconv(.c) usize {
    const s = sessionOfConst(handle) orelse return 0;
    return s.count();
}

/// Shown row title. NULL when handle/row is bad, or on OOM.
export fn badi_session_title(handle: ?*const BadiSession, index: usize) callconv(.c) ?[*:0]u8 {
    const e = rowOf(handle, index) orelse return null;
    return dupe(e.title);
}

/// Shown row subtitle (app comment). NULL when missing/bad/OOM, and always
/// NULL in lines mode.
export fn badi_session_subtitle(handle: ?*const BadiSession, index: usize) callconv(.c) ?[*:0]u8 {
    const e = rowOf(handle, index) orelse return null;
    const v = e.subtitle orelse return null;
    return dupe(v);
}

/// Shown row icon file. NULL when missing/bad/OOM, and always NULL in
/// lines mode.
export fn badi_session_icon(handle: ?*const BadiSession, index: usize) callconv(.c) ?[*:0]u8 {
    const e = rowOf(handle, index) orelse return null;
    const v = e.icon orelse return null;
    return dupe(v);
}

/// Move selection by `delta` rows, clamped. No-op on bad handle or empty
/// view.
export fn badi_session_move(handle: ?*BadiSession, delta: c_long) callconv(.c) void {
    const s = sessionOf(handle) orelse return;
    s.moveSelected(@intCast(delta));
}

/// Selected shown-row index, or -1 when handle is bad or the view is empty.
export fn badi_session_selected(handle: ?*const BadiSession) callconv(.c) c_long {
    const s = sessionOfConst(handle) orelse return -1;
    if (s.selectedEntry() == null) return -1;
    return @intCast(s.selected);
}

/// Spawn shown row `index` and return immediately (no waiting). Terminal
/// apps are wrapped in `$TERMINAL -e`. Returns 0 on spawn, -1 on bad
/// handle/row or when the row is not launchable (lines mode), -2 when the
/// spawn itself fails.
export fn badi_session_launch(handle: ?*BadiSession, index: usize) callconv(.c) c_int {
    const s = sessionOf(handle) orelse return -1;
    const io = launchIo();
    s.launch(io, index) catch |err| {
        if (err == error.OutOfMemory) return -2;
        return if (err == error.EmptyArgv) -1 else -2;
    };
    return 0;
}

/// Selected line in lines mode, as an owned copy. NULL in apps mode or
/// when handle/row is bad, or on OOM. Print it to stdout.
export fn badi_session_result(handle: ?*const BadiSession, index: usize) callconv(.c) ?[*:0]u8 {
    const e = rowOf(handle, index) orelse return null;
    if (e.app != null) return null; // apps mode has no result string
    return dupe(e.title);
}

/// Append piped lines to a lines-mode session (copied). Newcomers matching
/// the active query join the view in arrival order; selection is untouched.
/// Returns 0, -1 on bad handle, wrong mode (apps sessions), or OOM.
/// Empty appends are a no-op.
export fn badi_session_append(handle: ?*BadiSession, lines: ?[*]const [*:0]const u8, n: usize) callconv(.c) c_int {
    const s = sessionOf(handle) orelse return -1;
    if (lines) |ls| {
        if (n > 0) {
            const buf = c_alloc.alloc([]const u8, n) catch return -1;
            defer c_alloc.free(buf);
            for (buf, 0..) |*slot, i| slot.* = std.mem.span(ls[i]);
            s.appendLines(buf) catch return -1;
        }
    }
    return 0;
}

/// Free a session handle. NULL-safe.
export fn badi_session_destroy(handle: ?*BadiSession) callconv(.c) void {
    const h = handle orelse return;
    const box: *Box = @ptrCast(@alignCast(h));
    box.s.deinit();
    c_alloc.destroy(box);
}

// ---------------------------------------------------------------- helpers

/// Spawn-capable Io: `global_single_threaded` uses a failing allocator,
/// which `process.spawn` needs. Initialized once, lives until process exit
/// (sequential use only, like the rest of this API).
var threaded_storage: std.Io.Threaded = undefined;
var threaded_ready = false;

fn launchIo() std.Io {
    if (!threaded_ready) {
        threaded_storage = .init(c_alloc, .{});
        threaded_ready = true;
    }
    return threaded_storage.io();
}

fn sessionOf(handle: ?*BadiSession) ?*session.Session {
    const h = handle orelse return null;
    const box: *Box = @ptrCast(@alignCast(h));
    return &box.s;
}

fn sessionOfConst(handle: ?*const BadiSession) ?*const session.Session {
    const h = handle orelse return null;
    const box: *const Box = @ptrCast(@alignCast(h));
    return &box.s;
}

fn rowOf(handle: ?*const BadiSession, index: usize) ?session.Entry {
    // Entry is a plain value of borrowed slices; copying it out is safe.
    const s = sessionOfConst(handle) orelse return null;
    return s.row(index);
}

fn dupe(s: []const u8) ?[*:0]u8 {
    return c_alloc.dupeSentinel(u8, s, 0) catch return null;
}
