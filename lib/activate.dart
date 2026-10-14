import 'dart:io';

import 'session.dart';

/// What happens after the user picks a row or aborts.
///
/// Widgets report intent through this interface; only the implementation
/// below touches `exit()` / `stdout` / process spawning. That keeps process
/// lifetime out of the widget tree, so widget tests can inject a fake and
/// so a future frontend (GTK, CLI, …) can reuse the UI with different
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

/// Production implementation: real stdio, real spawn, real exit.
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
  Future<void> completeWithApp(LaunchTarget target) async {
    if (target.argv.isEmpty) throw StateError('empty launch argv');
    final argv = [
      if (target.terminal) ...terminalPrefix(),
      ...target.argv,
    ];
    // Detached: the child outlives the launcher, with no pipes back to us
    // (our stdout may be a picker pipe that closes on exit). The environment
    // is inherited, so HOME/DISPLAY/WAYLAND_* reach the child.
    await Process.start(
      argv.first,
      argv.skip(1).toList(),
      workingDirectory: target.cwd,
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  @override
  void cancel({required bool pipeMode}) => exit(pipeMode ? 1 : 0);
}

/// Terminal wrapper for `Terminal=true` apps: `$TERMINAL -e`, falling back
/// to `x-terminal-emulator -e` when unset.
List<String> terminalPrefix() {
  final term = Platform.environment['TERMINAL'];
  return [(term == null || term.isEmpty) ? 'x-terminal-emulator' : term, '-e'];
}

/// Default actions used when the UI doesn't inject its own (e.g. tests).
const processLauncherActions = ProcessLauncherActions();
