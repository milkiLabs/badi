import 'wm_workspace.dart';

/// Window-manager backend interface. The bar talks only to this + [WmWorkspace],
/// so adding Hyprland/i3/Niri later means adding one class and one line in
/// [createDefaultWmProvider] — no widget changes.
abstract class WmProvider {
  /// Stable id: `'sway'`, `'hyprland'`, ...
  String get id;

  /// False when the compositor socket is missing (wrong session).
  bool get available;

  /// Current snapshot. Throws on IPC failure; [WmService] converts that to
  /// an unavailable state instead of crashing the bar.
  Future<List<WmWorkspace>> fetchWorkspaces();

  /// Fires whenever the compositor hints the list may be stale (workspace /
  /// window events). Active only between [start] and [stop].
  Stream<void> get changes;

  /// Begin the event subscription. Idempotent.
  Future<void> start();

  /// End the event subscription. Idempotent.
  Future<void> stop();

  /// Request focus on [workspace]. Returns true when the compositor acked.
  Future<bool> focusWorkspace(WmWorkspace workspace);

  void dispose();
}
