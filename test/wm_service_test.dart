import 'dart:async';

import 'package:badi/platform/wm/wm_provider.dart';
import 'package:badi/platform/wm/wm_service.dart';
import 'package:badi/platform/wm/wm_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeProvider implements WmProvider {
  FakeProvider(this.list);

  List<WmWorkspace> list;
  final changesController = StreamController<void>.broadcast();
  var starts = 0;
  var stops = 0;
  WmWorkspace? lastFocused;

  @override
  String get id => 'fake';

  @override
  bool get available => true;

  @override
  Future<List<WmWorkspace>> fetchWorkspaces() async => list;

  @override
  Stream<void> get changes => changesController.stream;

  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<bool> focusWorkspace(WmWorkspace workspace) async {
    lastFocused = workspace;
    return true;
  }

  @override
  void dispose() {
    unawaited(changesController.close());
  }
}

const _ws1 = WmWorkspace(
  id: '1',
  name: '1: web',
  num: 1,
  focused: false,
  hasWindows: true,
);
const _ws2 = WmWorkspace(
  id: '2',
  name: '2',
  num: 2,
  focused: true,
  hasWindows: true,
);
const _wsEmpty = WmWorkspace(
  id: '3',
  name: '3',
  num: 3,
  focused: false,
  hasWindows: false,
);

void main() {
  test('start loads workspaces and filters visible', () async {
    final provider = FakeProvider([_ws1, _ws2, _wsEmpty]);
    final service = WmService.test(provider);
    addTearDown(service.dispose);

    service.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(service.available, isTrue);
    expect(service.backendId, 'fake');
    expect(service.workspaces.length, 3);
    expect(
      service.visibleWorkspaces.map((w) => w.id),
      ['1', '2'], // empty non-focused hidden
    );
    expect(service.focused?.id, '2');
    service.stop();
    expect(provider.starts, 1);
    expect(provider.stops, 1);
  });

  test('empty focused desk is still visible', () async {
    const emptyFocused = WmWorkspace(
      id: '4',
      name: '4',
      num: 4,
      focused: true,
      hasWindows: false,
    );
    final provider = FakeProvider([emptyFocused]);
    final service = WmService.test(provider);
    addTearDown(service.dispose);

    service.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(service.visibleWorkspaces.map((w) => w.id), ['4']);
    service.stop();
  });

  test('change events trigger refetch (debounced)', () async {
    final provider = FakeProvider([_ws1]);
    final service = WmService.test(provider);
    addTearDown(service.dispose);

    service.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(service.workspaces.length, 1);

    provider.list = [_ws1, _ws2];
    provider.changesController.add(null);
    provider.changesController.add(null); // burst coalesces
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(service.workspaces.length, 2);
    service.stop();
  });

  test('focus delegates and refreshes', () async {
    final provider = FakeProvider([_ws1, _ws2]);
    final service = WmService.test(provider);
    addTearDown(service.dispose);

    service.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await service.focus(_ws1), isTrue);
    expect(provider.lastFocused?.id, '1');
    service.stop();
  });

  test('no provider means unavailable, not a crash', () async {
    expect(createDefaultWmProvider({}), isNull);
  });
}
