//! C ABI
//!
//! This file exposes an opaque-handle API using only C types.
//! `zig_lib.h` is the source of truth for ffigen; keep the signatures in sync.
//!
//! Ownership:
//! - `badi_scan` returns a heap-owned list handle, free with `badi_scan_destroy`.
//! - `badi_scan_get_value` returns a heap-owned NUL-terminated copy
//!   (or NULL when missing), free with `badi_free_string`.
//! - All functions are null-tolerant and never panic across the FFI boundary.

const std = @import("std");
const parser = @import("desktop_parser.zig");

const c_alloc = std.heap.c_allocator;

/// Opaque handle owning a `parseAll` result. ABI-identical to
/// `struct BadiAppList` in `zig_lib.h`.
pub const BadiAppList = opaque {};

const ListBox = struct {
    docs: []parser.Document,
};

/// Free a string from `badi_scan_get_value`. NULL-safe.
export fn badi_free_string(s: ?[*:0]u8) callconv(.c) void {
    if (s == null) return;
    c_alloc.free(std.mem.span(s.?));
}

/// Scan system + user `applications` dirs and parse every `*.desktop` file.
/// `home_dir` (NULL = skip user dir) locates `~/.local/share/applications`.
/// Returns NULL only on OOM. Unreadable dirs/files are skipped, so a non-NULL
/// handle may still hold zero docs. Free with `badi_scan_destroy`.
///
/// Uses a single-threaded Io instance internally; sequential calls are fine,
/// concurrent calls from multiple threads are not supported.
export fn badi_scan(home_dir: ?[*:0]const u8) callconv(.c) ?*BadiAppList {
    const home: ?[]const u8 = if (home_dir) |h| std.mem.span(h) else null;
    const io = std.Io.Threaded.global_single_threaded.io();
    const docs = parser.parseAll(c_alloc, io, .{ .home_dir = home }) catch return null;
    const box = c_alloc.create(ListBox) catch {
        for (docs) |*d| d.deinit();
        c_alloc.free(docs);
        return null;
    };
    box.docs = docs;
    return @ptrCast(box);
}

/// Number of parsed docs. NULL-safe (NULL list = 0).
export fn badi_scan_count(list: ?*const BadiAppList) callconv(.c) usize {
    const l = list orelse return 0;
    const box: *const ListBox = @ptrCast(@alignCast(l));
    return box.docs.len;
}

/// Indexed lookup on a scanned doc, localized for `locale` (NULL = unlocalized).
/// Returns an owned NUL-terminated copy, or NULL when the
/// list/index/group/key is missing, or on OOM. Free with `badi_free_string`.
export fn badi_scan_get_value(
    list: ?*const BadiAppList,
    index: usize,
    group_name: ?[*:0]const u8,
    key: ?[*:0]const u8,
    locale: ?[*:0]const u8,
) callconv(.c) ?[*:0]u8 {
    const doc = scanItem(list, index) orelse return null;
    const g_name = group_name orelse return null;
    const k = key orelse return null;
    return lookupValue(doc.*, g_name, k, locale);
}

/// Free a handle from `badi_scan` and every doc it owns. NULL-safe.
/// Borrowed item access after this is use-after-free.
export fn badi_scan_destroy(list: ?*BadiAppList) callconv(.c) void {
    const l = list orelse return;
    const box: *ListBox = @ptrCast(@alignCast(l));
    for (box.docs) |*d| d.deinit();
    c_alloc.free(box.docs);
    c_alloc.destroy(box);
}

// ---------------------------------------------------------------- helpers

fn scanItem(list: ?*const BadiAppList, index: usize) ?*const parser.Document {
    const l = list orelse return null;
    const box: *const ListBox = @ptrCast(@alignCast(l));
    if (index >= box.docs.len) return null;
    return &box.docs[index];
}

fn lookupValue(
    doc: parser.Document,
    group_name: [*:0]const u8,
    key: [*:0]const u8,
    locale: ?[*:0]const u8,
) ?[*:0]u8 {
    const g = doc.group(std.mem.span(group_name)) orelse return null;
    const k_slice = std.mem.span(key);
    const v: ?[]const u8 = if (locale) |l|
        g.getLocalized(k_slice, std.mem.span(l))
    else
        g.get(k_slice);
    const value = v orelse return null;
    return c_alloc.dupeSentinel(u8, value, 0) catch return null;
}
