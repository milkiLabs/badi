import 'dart:convert';

import 'package:badi/platform/wm/wm_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses sway GET_WORKSPACES with nodes', () {
    final json = {
      'name': '2: ',
      'num': 2,
      'focused': true,
      'visible': true,
      'urgent': false,
      'output': 'HDMI-A-1',
      'nodes': [
        {'id': 9}
      ],
      'floating_nodes': [],
    };
    final ws = WmWorkspace.fromSwayJson(json);
    expect(ws.displayLabel, '2');
    expect(ws.focused, isTrue);
    expect(ws.hasWindows, isTrue);
    expect(ws.output, 'HDMI-A-1');
    expect(ws.id, '2');
  });

  test('empty workspace has no windows', () {
    final ws = WmWorkspace.fromSwayJson({
      'name': '5',
      'num': 5,
      'focused': true,
      'visible': true,
      'urgent': false,
      'nodes': [],
      'floating_nodes': [],
      'focus': [],
      'representation': null,
    });
    expect(ws.hasWindows, isFalse);
    expect(ws.displayLabel, '5');
  });

  test('floating-only counts as occupied', () {
    final ws = WmWorkspace.fromSwayJson({
      'name': '5',
      'num': 5,
      'focused': false,
      'visible': false,
      'nodes': [],
      'floating_nodes': [
        {'id': 1}
      ],
    });
    expect(ws.hasWindows, isTrue);
  });

  test('slim i3 payload falls back to representation', () {
    final withRepr = WmWorkspace.fromSwayJson({
      'name': '1',
      'num': 1,
      'focused': false,
      'visible': true,
      'representation': 'H[kitty]',
    });
    expect(withRepr.hasWindows, isTrue);

    final empty = WmWorkspace.fromSwayJson({
      'name': '2',
      'num': 2,
      'focused': false,
      'visible': false,
    });
    expect(empty.hasWindows, isFalse);
  });

  test('list skips scratchpad and sorts by num', () {
    final raw = jsonDecode('''
      [
        {"name": "9: ", "num": 9, "focused": false, "visible": false, "nodes": [{"id": 1}], "floating_nodes": []},
        {"name": "__i3_scratch", "num": -1, "focused": false, "visible": false, "nodes": [{"id": 2}], "floating_nodes": []},
        {"name": "1: ", "num": 1, "focused": false, "visible": false, "nodes": [{"id": 3}], "floating_nodes": []}
      ]
    ''');
    final list = WmWorkspace.listFromSwayJson(raw);
    expect(list.map((w) => w.displayLabel), ['1', '9']);
  });

  test('real sway 1.11 sample: empty nodes but repr+focus mark occupied', () {
    // Live `swaymsg -t get_workspaces` leaves nodes/floating empty even for
    // occupied desks; representation + focus stack carry the signal.
    final raw = jsonDecode('''
      [
        {"name": "1: ", "num": 1, "focused": false, "visible": false, "urgent": false, "output": "HDMI-A-1", "nodes": [], "floating_nodes": [], "focus": [19], "representation": "H[kitty]"},
        {"name": "2: ", "num": 2, "focused": true, "visible": true, "urgent": false, "output": "HDMI-A-1", "nodes": [], "floating_nodes": [], "focus": [10, 9], "representation": "H[kitty kitty]"},
        {"name": "5", "num": 5, "focused": false, "visible": false, "urgent": false, "output": "HDMI-A-1", "nodes": [], "floating_nodes": [], "focus": [], "representation": null},
        {"name": "9: ", "num": 9, "focused": false, "visible": false, "urgent": false, "output": "HDMI-A-1", "nodes": [], "floating_nodes": [], "focus": [7], "representation": "H[kitty]"}
      ]
    ''');
    final list = WmWorkspace.listFromSwayJson(raw);
    expect(list.length, 4);
    expect(list.where((w) => w.focused).single.displayLabel, '2');
    final occupied = list.where((w) => w.hasWindows).map((w) => w.displayLabel);
    expect(occupied, ['1', '2', '9']);
  });
}
