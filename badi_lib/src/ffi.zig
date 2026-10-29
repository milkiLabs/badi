//! C ABI for the picker core: filtered views over scanned apps or piped
//! input lines. The frontend owns rendering, the selection cursor, and
//! spawning; stdin line reading/batching, scan results, filtering, and row
//! data live here.
//!
//! `badi.h` is the source of truth for ffigen; keep the signatures in sync.
//!
//! Ownership:
//! - `badi_session_apps`/`badi_session_lines` return a heap-owned handle,
//!   free with `badi_session_destroy`.
//! - Every getter returns a heap-owned NUL-terminated copy (or NULL when
//!   missing), free with `badi_free_string`.
//! - All functions are null-tolerant and never panic across the FFI boundary.

const std = @import("std");
const session = @import("session.zig");
const sysmon = @import("sysmon.zig");
const network = @import("network.zig");
const desktop = @import("desktop.zig");
const stdin = @import("stdin.zig");

const c_alloc = std.heap.c_allocator;

/// Start Zig's asynchronous stdin reader. The callback receives one
/// newline-delimited batch at a time (event 0), followed by exactly one
/// terminal event: 1 for EOF or -1 for a read error. Each non-empty batch
/// must be released with `badi_stdin_batch_free` after it has been copied.
export fn badi_stdin_start(
    callback: ?stdin.Callback,
    context: ?*anyopaque,
) callconv(.c) c_int {
    const cb = callback orelse return -1;
    return if (stdin.start(cb, context)) 0 else -1;
}

/// Free a batch pointer delivered by the stdin callback. NULL-safe.
export fn badi_stdin_batch_free(batch: ?[*:0]const u8) callconv(.c) void {
    const ptr = batch orelse return;
    c_alloc.free(std.mem.span(ptr));
}

/// Opaque handle owning a picker session. ABI-identical to
/// `struct BadiSession` in `badi.h`.
pub const BadiSession = opaque {};
/// Opaque handle for one parsed document file.
pub const BadiDocument = opaque {};
/// Opaque handle for a scanned list of document files.
pub const BadiDesktopList = opaque {};

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
/// substring). Returns 0, -1 on bad handle or OOM (previous view is kept
/// on OOM). The frontend owns the cursor and resets it after calling this.
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

/// Launch argv length for shown row `index`. 0 when the handle/row is bad
/// or the row is not launchable (lines mode).
export fn badi_session_arg_count(handle: ?*const BadiSession, index: usize) callconv(.c) usize {
    const t = targetOf(handle, index) orelse return 0;
    return t.argv.len;
}

/// One launch argument as an owned copy. NULL when handle/row/arg is bad,
/// when the row is not launchable (lines mode), or on OOM.
export fn badi_session_arg(handle: ?*const BadiSession, index: usize, arg: usize) callconv(.c) ?[*:0]u8 {
    const t = targetOf(handle, index) orelse return null;
    if (arg >= t.argv.len) return null;
    return dupe(t.argv[arg]);
}

/// Whether shown row `index` wants a terminal wrapper. 1 when terminal,
/// 0 when not, -1 when handle/row is bad or the row is not launchable
/// (lines mode).
export fn badi_session_is_terminal(handle: ?*const BadiSession, index: usize) callconv(.c) c_int {
    const t = targetOf(handle, index) orelse return -1;
    return if (t.terminal) 1 else 0;
}

/// Working directory to launch shown row `index` in, as an owned copy.
/// NULL when unset, handle/row is bad, the row is not launchable (lines
/// mode), or on OOM. NULL cwd means inherit.
export fn badi_session_cwd(handle: ?*const BadiSession, index: usize) callconv(.c) ?[*:0]u8 {
    const t = targetOf(handle, index) orelse return null;
    const p = t.path orelse return null;
    return dupe(p);
}

/// Selected line in lines mode, as an owned copy. NULL in apps mode or
/// when handle/row is bad, or on OOM. Print it to stdout.
export fn badi_session_result(handle: ?*const BadiSession, index: usize) callconv(.c) ?[*:0]u8 {
    const e = rowOf(handle, index) orelse return null;
    if (e.app != null) return null; // apps mode has no result string
    return dupe(e.result);
}

/// Append piped lines to a lines-mode session (copied). Newcomers matching
/// the active query join the view in arrival order; existing rows never
/// move, so a frontend-owned cursor stays valid.
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

/// Append newline-delimited UTF-8 bytes directly, avoiding per-line decode
/// and re-encode work in the frontend. Blank rows are ignored.
export fn badi_session_append_utf8_lines(
    handle: ?*BadiSession,
    bytes: ?[*]const u8,
    byte_len: usize,
) callconv(.c) c_int {
    const s = sessionOf(handle) orelse return -1;
    if (byte_len == 0) return 0;
    const input = bytes orelse return -1;
    s.appendUtf8Lines(input[0..byte_len]) catch return -1;
    return 0;
}

/// Free a session handle. NULL-safe.
export fn badi_session_destroy(handle: ?*BadiSession) callconv(.c) void {
    const h = handle orelse return;
    const box: *Box = @ptrCast(@alignCast(h));
    box.s.deinit();
    c_alloc.destroy(box);
}

/// ABI mirrors `BadiCpuSnapshot` in `badi.h`.
pub const BadiCpuSnapshot = sysmon.CpuSnapshot;
/// ABI mirrors `BadiMemInfo` in `badi.h`.
pub const BadiMemInfo = sysmon.MemInfo;

/// Fill `out` with current CPU counters. 0 on success, -1 on NULL out
/// or read/parse failure. Pair two snapshots with
/// `badi_cpu_usage_between` to get utilization.
export fn badi_cpu_snapshot(out: ?*BadiCpuSnapshot) callconv(.c) c_int {
    const dst = out orelse return -1;
    return if (sysmon.snapshotCpu(dst)) 0 else -1;
}

/// Utilization fraction 0..1 between two snapshots, or -1 when the pair
/// is invalid (NULL pointers, zero delta, counters backwards). The first
/// sample of a session has no previous sample: expect -1 once.
export fn badi_cpu_usage_between(prev: ?*const BadiCpuSnapshot, cur: ?*const BadiCpuSnapshot) callconv(.c) f64 {
    const p = prev orelse return -1;
    const c = cur orelse return -1;
    return sysmon.cpuUsageBetween(p.*, c.*);
}

/// Fill `out` with current memory totals. 0 on success, -1 on NULL out
/// or read/parse failure.
export fn badi_mem_snapshot(out: ?*BadiMemInfo) callconv(.c) c_int {
    const dst = out orelse return -1;
    return if (sysmon.snapshotMem(dst)) 0 else -1;
}

/// Current download rate in bytes per second, or -1 until two samples exist
/// or when the default-route interface cannot be read.
export fn badi_network_download_speed() callconv(.c) f64 {
    return network.snapshotDownloadBytesPerSecond();
}

// ---------------------------------------------------------------- document files (simplified parser)

const DocBox = struct { doc: desktop.Document };
const ListDocBox = struct { docs: []desktop.Document };

export fn badi_document_parse(source: ?[*:0]const u8) callconv(.c) ?*BadiDocument {
    const src = if (source) |s| std.mem.span(s) else return null;
    const box = c_alloc.create(DocBox) catch return null;
    box.doc = desktop.parseDoc(c_alloc, src) catch {
        c_alloc.destroy(box);
        return null;
    };
    return @ptrCast(box);
}

export fn badi_document_free(handle: ?*BadiDocument) callconv(.c) void {
    const h = handle orelse return;
    const box: *DocBox = @ptrCast(@alignCast(h));
    box.doc.deinit();
    c_alloc.destroy(box);
}

fn docOf(handle: ?*const BadiDocument) ?*const DocBox {
    const h = handle orelse return null;
    return @ptrCast(@alignCast(h));
}

export fn badi_document_type(handle: ?*const BadiDocument) callconv(.c) ?[*:0]u8 {
    const box = docOf(handle) orelse return null;
    if (box.doc.Type.len == 0) return null;
    return dupe(box.doc.Type);
}
export fn badi_document_name(handle: ?*const BadiDocument) callconv(.c) ?[*:0]u8 {
    const box = docOf(handle) orelse return null;
    if (box.doc.Name.len == 0) return null;
    return dupe(box.doc.Name);
}
export fn badi_document_icon(handle: ?*const BadiDocument) callconv(.c) ?[*:0]u8 {
    const box = docOf(handle) orelse return null;
    if (box.doc.Icon.len == 0) return null;
    return dupe(box.doc.Icon);
}
export fn badi_document_exec(handle: ?*const BadiDocument) callconv(.c) ?[*:0]u8 {
    const box = docOf(handle) orelse return null;
    if (box.doc.Exec.len == 0) return null;
    return dupe(box.doc.Exec);
}

export fn badi_desktop_scan() callconv(.c) ?*BadiDesktopList {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dirs = desktop.getDesktopDirs(c_alloc) catch return null;
    defer {
        for (dirs) |d| c_alloc.free(d);
        c_alloc.free(dirs);
    }
    const docs = desktop.getParsedDesktopEntries(c_alloc, io, dirs) catch return null;
    const box = c_alloc.create(ListDocBox) catch {
        for (docs) |*d| d.deinit();
        c_alloc.free(docs);
        return null;
    };
    box.docs = docs;
    return @ptrCast(box);
}

export fn badi_desktop_list_count(handle: ?*const BadiDesktopList) callconv(.c) usize {
    const box = listDocOf(handle) orelse return 0;
    return box.docs.len;
}

export fn badi_desktop_list_name(handle: ?*const BadiDesktopList, index: usize) callconv(.c) ?[*:0]u8 {
    const box = listDocOf(handle) orelse return null;
    if (index >= box.docs.len) return null;
    const v = box.docs[index].Name;
    if (v.len == 0) return null;
    return dupe(v);
}
export fn badi_desktop_list_type(handle: ?*const BadiDesktopList, index: usize) callconv(.c) ?[*:0]u8 {
    const box = listDocOf(handle) orelse return null;
    if (index >= box.docs.len) return null;
    const v = box.docs[index].Type;
    if (v.len == 0) return null;
    return dupe(v);
}
export fn badi_desktop_list_icon(handle: ?*const BadiDesktopList, index: usize) callconv(.c) ?[*:0]u8 {
    const box = listDocOf(handle) orelse return null;
    if (index >= box.docs.len) return null;
    const v = box.docs[index].Icon;
    if (v.len == 0) return null;
    return dupe(v);
}
export fn badi_desktop_list_exec(handle: ?*const BadiDesktopList, index: usize) callconv(.c) ?[*:0]u8 {
    const box = listDocOf(handle) orelse return null;
    if (index >= box.docs.len) return null;
    const v = box.docs[index].Exec;
    if (v.len == 0) return null;
    return dupe(v);
}

export fn badi_desktop_list_free(handle: ?*BadiDesktopList) callconv(.c) void {
    const h = handle orelse return;
    const box: *ListDocBox = @ptrCast(@alignCast(h));
    for (box.docs) |*d| d.deinit();
    c_alloc.free(box.docs);
    c_alloc.destroy(box);
}

fn listDocOf(handle: ?*const BadiDesktopList) ?*const ListDocBox {
    const h = handle orelse return null;
    return @ptrCast(@alignCast(h));
}

// ---------------------------------------------------------------- helpers

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

fn targetOf(handle: ?*const BadiSession, index: usize) ?session.Session.App {
    // App is arena-owned; the caller dupes what it keeps.
    const s = sessionOfConst(handle) orelse return null;
    return s.target(index);
}

fn dupe(s: []const u8) ?[*:0]u8 {
    return c_alloc.dupeSentinel(u8, s, 0) catch return null;
}
