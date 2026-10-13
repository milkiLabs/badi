//! C ABI for the launcher: list apps, launch apps.
//!
//! `zig_lib.h` is the source of truth for ffigen; keep the signatures in sync.
//!
//! Ownership:
//! - `badi_apps_scan` returns a heap-owned handle, free with `badi_apps_destroy`.
//! - Every `badi_apps_*` getter returns a heap-owned NUL-terminated copy
//!   (or NULL when missing), free with `badi_free_string`.
//! - All functions are null-tolerant and never panic across the FFI boundary.

const std = @import("std");
const apps = @import("apps.zig");

const c_alloc = std.heap.c_allocator;

/// Opaque handle owning a scan result. ABI-identical to
/// `struct BadiAppList` in `zig_lib.h`.
pub const BadiAppList = opaque {};

const Box = struct {
    list: apps.AppList,
};

/// Free a string from any `badi_apps_*` getter. NULL-safe.
export fn badi_free_string(s: ?[*:0]u8) callconv(.c) void {
    if (s == null) return;
    c_alloc.free(std.mem.span(s.?));
}

/// Scan system + user `applications` dirs for launchable apps.
/// `home_dir` (NULL = skip user dir) locates `~/.local/share/applications`;
/// `locale` (NULL = unlocalized) picks localized Name/Icon/Comment.
/// Returns NULL only on OOM. Free with `badi_apps_destroy`.
///
/// Uses a single-threaded Io instance internally; sequential calls are fine,
/// concurrent calls from multiple threads are not supported.
export fn badi_apps_scan(home_dir: ?[*:0]const u8, locale: ?[*:0]const u8) callconv(.c) ?*BadiAppList {
    const home: ?[]const u8 = if (home_dir) |h| std.mem.span(h) else null;
    const lang: ?[]const u8 = if (locale) |l| std.mem.span(l) else null;
    const io = std.Io.Threaded.global_single_threaded.io();
    const box = c_alloc.create(Box) catch return null;
    box.list = apps.scan(c_alloc, io, home, lang) catch {
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

/// Raw Exec value, unescaped, for display. NULL when bad/OOM.
export fn badi_apps_exec(handle: ?*const BadiAppList, index: usize) callconv(.c) ?[*:0]u8 {
    const app = itemOf(handle, index) orelse return null;
    return dupe(app.exec);
}

/// Icon name or path. NULL when missing/bad/OOM.
export fn badi_apps_icon(handle: ?*const BadiAppList, index: usize) callconv(.c) ?[*:0]u8 {
    const app = itemOf(handle, index) orelse return null;
    const v = app.icon orelse return null;
    return dupe(v);
}

/// Comment/description. NULL when missing/bad/OOM.
export fn badi_apps_comment(handle: ?*const BadiAppList, index: usize) callconv(.c) ?[*:0]u8 {
    const app = itemOf(handle, index) orelse return null;
    const v = app.comment orelse return null;
    return dupe(v);
}

/// Raw Keywords value for search matching. NULL when missing/bad/OOM.
export fn badi_apps_keywords(handle: ?*const BadiAppList, index: usize) callconv(.c) ?[*:0]u8 {
    const app = itemOf(handle, index) orelse return null;
    const v = app.keywords orelse return null;
    return dupe(v);
}

/// Working directory to launch in. NULL when missing/bad/OOM.
export fn badi_apps_path(handle: ?*const BadiAppList, index: usize) callconv(.c) ?[*:0]u8 {
    const app = itemOf(handle, index) orelse return null;
    const v = app.path orelse return null;
    return dupe(v);
}

/// 1 when the app must run in a terminal, 0 when not, -1 when handle/index is bad.
export fn badi_apps_is_terminal(handle: ?*const BadiAppList, index: usize) callconv(.c) c_int {
    const app = itemOf(handle, index) orelse return -1;
    return if (app.terminal) 1 else 0;
}

/// Number of launch arguments. -1 when handle/index is bad.
export fn badi_apps_argc(handle: ?*const BadiAppList, index: usize) callconv(.c) c_int {
    const app = itemOf(handle, index) orelse return -1;
    return @intCast(app.argv.len);
}

/// One launch argument (0-based). NULL when out of range/bad/OOM.
/// Launch with exactly these arguments; no field codes remain.
export fn badi_apps_argv(handle: ?*const BadiAppList, index: usize, arg: usize) callconv(.c) ?[*:0]u8 {
    const app = itemOf(handle, index) orelse return null;
    if (arg >= app.argv.len) return null;
    return dupe(app.argv[arg]);
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
