import 'package:badi/core/actions.dart';
import 'package:badi/core/session.dart';
import 'package:badi/shell/shell_actions.dart';
import 'package:badi/shell/shell_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeActions implements LauncherActions {
  @override
  Future<void> completeWithLine(String line) async {}

  @override
  Future<void> completeWithApp(LaunchTarget target) async {}

  @override
  void cancel({required bool pipeMode}) {}
}

void main() {
  test('starts closed', () {
    final shell = ShellController();
    addTearDown(shell.dispose);
    expect(shell.launcherOpen, isFalse);
    expect(shell.mode, isNull);
    expect(shell.currentActions, isNull);
    expect(shell.piped, isNull);
  });

  test('openApps opens, busy second open fails, close reopens', () {
    final shell = ShellController();
    addTearDown(shell.dispose);
    var notifications = 0;
    shell.addListener(() => notifications++);

    expect(shell.openApps(actions: FakeActions()), isTrue);
    expect(shell.launcherOpen, isTrue);
    expect(shell.mode, ShellRequestMode.apps);
    expect(shell.currentActions, isNotNull);
    expect(shell.piped, isNull);

    expect(shell.openApps(actions: FakeActions()), isFalse);
    expect(shell.openLines(actions: FakeActions()), isFalse);

    shell.closeLauncher();
    expect(shell.launcherOpen, isFalse);
    expect(shell.currentActions, isNull);
    expect(shell.openApps(actions: FakeActions()), isTrue);
    expect(notifications, 3); // open, close, open (busy opens stay silent)
  });

  test('openLines pipes input until eof', () async {
    final shell = ShellController();
    addTearDown(shell.dispose);
    expect(shell.openLines(actions: FakeActions()), isTrue);
    expect(shell.mode, ShellRequestMode.lines);

    final received = <String>[];
    final done = shell.piped!.fold<List<String>>(
      received,
      (acc, line) => acc..add(line),
    );
    shell.appendLine('one');
    shell.appendLine('two');
    shell.closeInput();
    expect(await done, ['one', 'two']);

    shell.closeLauncher();
    expect(shell.launcherOpen, isFalse);
  });

  test('input and close are safe when closed', () async {
    final shell = ShellController();
    addTearDown(shell.dispose);
    shell.appendLine('ignored');
    shell.closeInput();
    shell.closeLauncher(); // no notify, no crash
    expect(shell.launcherOpen, isFalse);
  });

  test('generation bumps per open for view keys', () {
    final shell = ShellController();
    addTearDown(shell.dispose);
    final first = shell.generation;
    shell.openApps(actions: FakeActions());
    expect(shell.generation, greaterThan(first));
    shell.closeLauncher();
    shell.openLines(actions: FakeActions());
    expect(shell.generation, greaterThan(first + 1));
  });

  test('pipe actions answer then close, once', () async {
    final shell = ShellController();
    addTearDown(shell.dispose);
    final answers = <String>[];
    var closes = 0;
    final tracking = _TrackingShell(shell, onClose: () => closes++);
    tracking.openPipeForTest(
      replyResult: (line) async => answers.add('result:$line'),
      replyCancelled: () async => answers.add('cancelled'),
    );

    final actions = shell.currentActions!;
    await actions.completeWithLine('hi');
    // Already answered: late calls are dropped, never re-reply.
    await actions.completeWithLine('again');
    actions.cancel(pipeMode: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(answers, ['result:hi']); // exactly one reply
    expect(closes, 1);
    expect(shell.launcherOpen, isFalse);
  });

  test('app actions spawn failures keep the launcher open', () async {
    final shell = ShellController();
    addTearDown(shell.dispose);
    shell.openApps(actions: ShellAppActions(onDone: shell.closeLauncher));
    // Empty argv cannot spawn: the error propagates, nothing closes.
    await expectLater(
      shell.currentActions!.completeWithApp(
        const LaunchTarget(argv: [], terminal: false),
      ),
      throwsStateError,
    );
    expect(shell.launcherOpen, isTrue);
  });
}

/// Opens a lines request on [shell] while counting [ShellController.closeLauncher]
/// calls via the wrapped callback.
class _TrackingShell {
  _TrackingShell(this.shell, {required this.onClose});

  final ShellController shell;
  final void Function() onClose;

  void openPipeForTest({
    required Future<void> Function(String) replyResult,
    required Future<void> Function() replyCancelled,
  }) {
    shell.openLines(
      actions: ShellPipeActions(
        replyResult: replyResult,
        replyCancelled: replyCancelled,
        onDone: () {
          onClose();
          shell.closeLauncher();
        },
      ),
    );
  }
}
