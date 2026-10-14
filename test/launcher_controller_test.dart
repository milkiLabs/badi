import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:badi/core/actions.dart';
import 'package:badi/core/launcher_controller.dart';
import 'package:badi/core/session.dart';
import 'package:badi/platform/zig.dart';

class FakeActions implements LauncherActions {
  final pickedLines = <String>[];
  final launched = <LaunchTarget>[];
  final cancels = <bool>[];
  bool throwOnLaunch = false;

  @override
  Future<void> completeWithLine(String line) async {
    pickedLines.add(line);
  }

  @override
  Future<void> completeWithApp(LaunchTarget target) async {
    if (throwOnLaunch) throw StateError('nope');
    launched.add(target);
  }

  @override
  void cancel({required bool pipeMode}) {
    cancels.add(pipeMode);
  }
}

LauncherController controller({
  required FakeActions actions,
  Stream<String>? piped,
  List<String> apps = const ['alpha', 'beta', 'alphabet'],
}) {
  final c = LauncherController(
    actions: actions,
    piped: piped,
    openApps: () => Session.lines(apps, lib: badiLib),
    openLines: (first) => Session.lines([first], lib: badiLib),
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> settle([int ms = 50]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('terminal opens apps immediately', () {
    final actions = FakeActions();
    final c = controller(actions: actions)..attach();
    expect(c.loading, isFalse);
    expect(c.pipeMode, isFalse);
    expect(c.count, 3);
    expect(c.selected, 0);
  });

  test('query filters and resets cursor', () {
    final actions = FakeActions();
    final c = controller(actions: actions)..attach();
    c.move(2);
    expect(c.selected, 2);
    c.setQuery('alph');
    expect(c.count, 2);
    expect(c.selected, 0);
    expect(c.rowAt(0).title, 'alpha');
    expect(c.rowAt(1).title, 'alphabet');
  });

  test('move clamps, no-ops when empty', () {
    final actions = FakeActions();
    final c = controller(actions: actions)..attach();
    c.move(99);
    expect(c.selected, 2);
    c.move(-99);
    expect(c.selected, 0);
    c.setQuery('zzz');
    expect(c.count, 0);
    c.move(1); // no crash
    expect(c.selected, 0);
  });

  test('first piped line flips to pipe mode', () async {
    final actions = FakeActions();
    final c = controller(
      actions: actions,
      piped: Stream.value('hello'),
    )..attach();
    await settle();
    expect(c.pipeMode, isTrue);
    expect(c.count, 1);
    await c.activate(0);
    expect(actions.pickedLines, ['hello']);
  });

  test('empty pipe at EOF falls back to apps', () async {
    final actions = FakeActions();
    final c = controller(
      actions: actions,
      piped: const Stream.empty(),
    )..attach();
    await settle();
    expect(c.pipeMode, isFalse);
    expect(c.count, 3);
  });

  test('batches append without moving cursor', () async {
    final actions = FakeActions();
    final lines = Stream.fromIterable(['one', 'two', 'three']);
    final c = controller(
      actions: actions,
      piped: lines,
    )..attach();
    await settle(200);
    expect(c.pipeMode, isTrue);
    expect(c.count, 3);
    expect(c.selected, 0);
    expect(c.streamDone, isTrue);
  });

  test('launch failure surfaces as error, no exit', () async {
    final actions = FakeActions()..throwOnLaunch = true;
    // Lines sessions have no launch target: exercises the wrong-mode path.
    final c = controller(actions: actions)..attach();
    await c.activate(0);
    expect(actions.launched, isEmpty);
    expect(c.actionError, contains('Failed to launch'));
  });

  test('cancel forwards pipe mode', () async {
    final appsActions = FakeActions();
    controller(actions: appsActions)..attach()..cancel();
    expect(appsActions.cancels, [false]);

    final pipeActions = FakeActions();
    final c = controller(
      actions: pipeActions,
      piped: Stream.value('x'),
    )..attach();
    await settle();
    c.cancel();
    expect(pipeActions.cancels, [true]);
  });

  test('detach silences late stream events', () async {
    final actions = FakeActions();
    final sc = StreamController<String>();
    addTearDown(sc.close);
    final c = controller(actions: actions, piped: sc.stream)..attach();
    c.detach();
    sc.add('late');
    await settle();
    expect(c.count, 0); // terminal-path never ran; nothing attached
  });
}
