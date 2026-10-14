import 'dart:async';
import 'dart:io';

import '../core/actions.dart';
import '../core/session.dart';
import '../platform/process_actions.dart';

/// Spawns [target] detached, inheriting the environment. Shared by shell
/// actions and re-exposed for tests; failures throw so the UI can show an
/// error instead of closing.
Future<void> spawnAppTarget(LaunchTarget target) async {
  if (target.argv.isEmpty) throw StateError('empty launch argv');
  final argv = [
    if (target.terminal) ...terminalPrefix(),
    ...target.argv,
  ];
  // Detached: the child outlives the shell, with no pipes back to us.
  await Process.start(
    argv.first,
    argv.skip(1).toList(),
    workingDirectory: target.cwd,
    mode: ProcessStartMode.detached,
  );
}

/// Apps-mode completion inside the long-lived shell: spawn, then hide the
/// launcher instead of exiting. Used for keybinding opens and bar clicks.
class ShellAppActions implements LauncherActions {
  ShellAppActions({required this.onDone});

  final void Function() onDone;

  @override
  Future<void> completeWithLine(String line) async {
    throw StateError('no selectable line in apps mode');
  }

  @override
  Future<void> completeWithApp(LaunchTarget target) async {
    await spawnAppTarget(target);
    onDone();
  }

  @override
  void cancel({required bool pipeMode}) => onDone();
}

/// Lines-mode completion: answers the waiting IPC client over its socket,
/// then hides the launcher. The daemon never prints picks to its own
/// stdout; only the client does.
class ShellPipeActions implements LauncherActions {
  ShellPipeActions({
    required this.replyResult,
    required this.replyCancelled,
    required this.onDone,
  });

  final Future<void> Function(String line) replyResult;
  final Future<void> Function() replyCancelled;
  final void Function() onDone;

  bool _done = false;

  @override
  Future<void> completeWithLine(String line) async {
    if (_done) return;
    _done = true;
    try {
      await replyResult(line);
    } finally {
      onDone();
    }
  }

  @override
  Future<void> completeWithApp(LaunchTarget target) async {
    // Empty-pipe fallback shows apps while a lines client waits. The human
    // still gets their launch; the client asked for lines, so it gets a
    // cancel (rofi-style: no line was selected).
    if (_done) return;
    _done = true;
    await spawnAppTarget(target);
    try {
      await replyCancelled();
    } finally {
      onDone();
    }
  }

  @override
  void cancel({required bool pipeMode}) {
    if (_done) return;
    _done = true;
    // The interface is sync; reply in the background and always hide.
    unawaited(
      replyCancelled().then((_) => onDone(), onError: (_) => onDone()),
    );
  }
}
