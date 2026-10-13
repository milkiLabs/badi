//! C ABI for the launcher backend: list apps, search apps, launch apps.
//!
//! `zig_lib.h` is the source of truth for ffigen; keep the signatures in sync.
//!
//! Ownership:
//! - `badi_apps_scan` returns a heap-owned handle, free with `badi_apps_destroy`.
//! - `badi_apps_search` returns a heap-owned handle, free with `badi_found_destroy`.
//! - Every getter returns a heap-owned NUL-terminated copy (or NULL when
//!   missing), free with `badi_free_string`.
//! - All functions are null-tolerant and never panic across the FFI boundary.

const std = @import("std");
const apps = @import("apps.zig");

const c_alloc = std.heap.c_allocator;

/// Opaque handle owning a scan result. ABI-identical to
/// `struct BadiAppList` in `zig_lib.h`.
pub const BadiAppList = opaque {};

/// Opaque handle owning search result indices. ABI-identical to
/// `struct BadiFound` in `zig_lib.h`.
pub const BadiFound = opaque {};

const Box = struct {
    list: apps.AppList,
};

const FoundBox = struct {
    indices: []usize,
};

/// Free a string from any getter. NULL-safe.
export fn badi_free_string(s: ?[*:0]u8) callconv(.c) void {
    if (s == null) return;
    c_alloc.free(std.mem.span(s.?));
}

/// Scan system + user `applications` dirs for launchable apps, sorted by
/// name. `$HOME` locates `~/.local/share/applications` (read from the
/// process environment inside the scan); `locale` (NULL = unlocalized)
/// picks localized Name/Icon/Comment. Returns NULL only on OOM.
/// Free with `badi_apps_destroy`.
///
/// Uses a single-threaded Io instance internally; sequential calls are fine,
/// concurrent calls from multiple threads are not supported.
export fn badi_apps_scan(locale: ?[*:0]const u8) callconv(.c) ?*BadiAppList {
    const lang: ?[]const u8 = if (locale) |l| std.mem.span(l) else null;
    const io = std.Io.Threaded.global_single_threaded.io();
    const box = c_alloc.create(Box) catch return null;
    box.list = apps.scan(c_alloc, io, lang) catch {
        c_alloc.destroy(box);
        return null;
    };
    return @ptrCast(box);
}

/// Number of apps. NULL-safe (NULL handle = 0).
export fn badi_apps_count(handle: ?*const BadiAppList) callconv(.c) usize {
    const box = boxOf(handle) orelse return 0;
    return box.list.apps.len;
}

/// App display name. NULL when handle/index is bad, or on OOM.
export fn badi_apps_name(handle: ?*const BadiAppList, index: usize) callconv(.c) ?[*:0]u8 {
    const app = itemOf(handle, index) orelse return null;
    return dupe(app.name);
}

/// Comment/description. NULL when missing/bad/OOM.
export fn badi_apps_comment(handle: ?*const BadiAppList, index: usize) callconv(.c) ?[*:0]u8 {
    const app = itemOf(handle, index) orelse return null;
    const v = app.comment orelse return null;
    return dupe(v);
}

/// Resolved icon file. NULL when missing/bad/OOM.
export fn badi_apps_icon_path(handle: ?*const BadiAppList, index: usize) callconv(.c) ?[*:0]u8 {
    const app = itemOf(handle, index) orelse return null;
    const v = app.icon_path orelse return null;
    return dupe(v);
}

/// Indices of apps matching `query` (ASCII case-insensitive substring;
/// NULL/blank matches all), in sort order. NULL only on OOM.
/// Free with `badi_found_destroy`.
export fn badi_apps_search(handle: ?*const BadiAppList, query: ?[*:0]const u8) callconv(.c) ?*BadiFound {
    const box = boxOf(handle) orelse return null;
    const q: ?[]const u8 = if (query) |s| std.mem.span(s) else null;
    const found = c_alloc.create(FoundBox) catch return null;
    found.indices = apps.search(c_alloc, box.list.apps, q) catch {
        c_alloc.destroy(found);
        return null;
    };
    return @ptrCast(found);
}

/// Number of matches. NULL-safe (NULL handle = 0).
export fn badi_found_count(handle: ?*const BadiFound) callconv(.c) usize {
    const h = handle orelse return 0;
    const found: *const FoundBox = @ptrCast(@alignCast(h));
    return found.indices.len;
}

/// App index of match `n`. -1 when handle/n is bad.
export fn badi_found_at(handle: ?*const BadiFound, n: usize) callconv(.c) c_long {
    const h = handle orelse return -1;
    const found: *const FoundBox = @ptrCast(@alignCast(h));
    if (n >= found.indices.len) return -1;
    return @intCast(found.indices[n]);
}

/// Free a handle from `badi_apps_search`. NULL-safe.
export fn badi_found_destroy(handle: ?*BadiFound) callconv(.c) void {
    const h = handle orelse return;
    const found: *FoundBox = @ptrCast(@alignCast(h));
    c_alloc.free(found.indices);
    c_alloc.destroy(found);
}

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

/// Spawn the app and return immediately (no waiting). Terminal apps are
/// wrapped in `$TERMINAL -e` (NULL/empty falls back to "x-terminal-emulator").
/// Returns 0 on spawn, -1 on bad handle/index or empty argv, -2 when the
/// spawn itself fails.
export fn badi_apps_launch(handle: ?*const BadiAppList, index: usize) callconv(.c) c_int {
    const app = itemOf(handle, index) orelse return -1;
    const io = launchIo();
    const term = apps.getenv("TERMINAL");
    apps.launch(c_alloc, io, app.*, term) catch |err| {
        if (err == error.OutOfMemory) return -2;
        return if (err == error.EmptyArgv) -1 else -2;
    };
    return 0;
}

/// Free a handle from `badi_apps_scan`. NULL-safe.
export fn badi_apps_destroy(handle: ?*BadiAppList) callconv(.c) void {
    const h = handle orelse return;
    const box: *Box = @ptrCast(@alignCast(h));
    box.list.deinit();
    c_alloc.destroy(box);
}

// ---------------------------------------------------------------- helpers

fn boxOf(handle: ?*const BadiAppList) ?*const Box {
    const h = handle orelse return null;
    return @ptrCast(@alignCast(h));
}

fn itemOf(handle: ?*const BadiAppList, index: usize) ?*const apps.App {
    const box = boxOf(handle) orelse return null;
    if (index >= box.list.apps.len) return null;
    return &box.list.apps[index];
}

fn dupe(s: []const u8) ?[*:0]u8 {
    return c_alloc.dupeSentinel(u8, s, 0) catch return null;
}
