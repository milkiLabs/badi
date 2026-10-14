import 'dart:io';

import 'session.dart';

/// What happens after the user picks a row or aborts.
///
/// Widgets report intent through this interface; only the implementation
/// below touches `exit()` / `stdout`. That keeps process lifetime out of
/// the widget tree, so widget tests can inject a fake and so a future
/// frontend (GTK, CLI, …) can reuse the UI with different completion.
abstract interface class LauncherActions {
  /// Pipe mode: the picked line. Prints, flushes, and exits 0.
  Future<void> completeWithLine(String line);

  /// Apps mode: spawns row `index` and exits 0.
  /// Throws on failure so the UI can show an error instead of exiting.
  Future<void> completeWithApp(Session session, int index);

  /// User aborted (Escape). Pipe mode exits 1 (rofi-style: no selection),
  /// apps mode exits 0.
  void cancel({required bool pipeMode});
}

class ProcessLauncherActions implements LauncherActions {
  const ProcessLauncherActions();

  @override
  Future<void> completeWithLine(String line) async {
    stdout.writeln(line);
    // `exit` never flushes stdout on its own, so flush first.
    await stdout.flush();
    exit(0);
  }

  @override
  Future<void> completeWithApp(Session session, int index) async {
    session.launch(index);
    exit(0);
  }

  @override
  void cancel({required bool pipeMode}) => exit(pipeMode ? 1 : 0);
}

/// Default actions used when the UI doesn't inject its own (e.g. tests).
const processLauncherActions = ProcessLauncherActions();
