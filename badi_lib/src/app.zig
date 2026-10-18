//! The launcher's app record. Kept in its own file so `parse`, `apps`,
//! and `ffi` can share it without import cycles.

/// One launchable application. Every string (and `argv`) is arena-owned;
/// see `apps.AppList`.
pub const App = struct {
    name: []const u8,
    /// `Exec` expanded to launch arguments: field codes resolved, quoting
    /// applied, no targets (a launcher starts the app bare).
    argv: []const []const u8 = &.{},
    comment: ?[]const u8 = null,
    /// Working directory to launch in.
    path: ?[]const u8 = null,
    terminal: bool = false,
    /// Lowercase ASCII search blob: name, comment, keywords, exec.
    /// Non-ASCII bytes pass through untouched (they have no ASCII case).
    hay: []const u8 = "",
};
