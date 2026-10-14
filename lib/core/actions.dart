import 'session.dart';

/// What happens after the user picks a row or aborts.
///
/// Widgets and controllers report intent through this interface; only a
/// platform implementation touches `exit()` / `stdout` / process spawning.
/// That keeps process lifetime out of the UI and core layers, so tests can
/// inject a fake and a future frontend can reuse them with different
/// completion.
abstract interface class LauncherActions {
  /// Pipe mode: the picked line. Prints, flushes, and exits 0.
  Future<void> completeWithLine(String line);

  /// Apps mode: spawns `target` detached and exits 0.
  /// Throws on failure so the UI can show an error instead of exiting.
  Future<void> completeWithApp(LaunchTarget target);

  /// User aborted (Escape). Pipe mode exits 1 (rofi-style: no selection),
  /// apps mode exits 0.
  void cancel({required bool pipeMode});
}
