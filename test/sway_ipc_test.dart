import 'dart:convert';
import 'dart:typed_data';

import 'package:badi/platform/wm/sway_ipc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encode/decode round-trips', () {
    final frame = SwayIpc.encode(SwayIpc.getWorkspaces, '[]');
    final decoded = SwayIpc.tryDecode(frame.toList());
    expect(decoded, isNotNull);
    expect(decoded!.$1, SwayIpc.getWorkspaces);
    expect(decoded.$2, '[]');
    expect(decoded.$3, frame.length);
  });

  test('tryDecode waits for full payload', () {
    final frame = SwayIpc.encode(1, '{"a":1}');
    final partial = frame.sublist(0, 10).toList();
    expect(SwayIpc.tryDecode(partial), isNull);
    // Header present but body truncated.
    final headerPlusOne =
        frame.sublist(0, SwayIpc.headerLength + 1).toList();
    expect(SwayIpc.tryDecode(headerPlusOne), isNull);
  });

  test('tryDecode handles back-to-back frames', () {
    final a = SwayIpc.encode(1, '[1]');
    final b = SwayIpc.encode(0, '[2]');
    final combined = Uint8List.fromList([...a, ...b]);
    final first = SwayIpc.tryDecode(combined.toList())!;
    expect(first.$2, '[1]');
    final second =
        SwayIpc.tryDecode(combined.sublist(first.$3).toList())!;
    expect(second.$1, 0);
    expect(second.$2, '[2]');
  });

  test('bad magic throws', () {
    expect(
      () => SwayIpc.tryDecode(List.filled(14, 0)),
      throwsFormatException,
    );
  });

  test('swaySocketPath prefers SWAYSOCK then I3SOCK', () {
    expect(swaySocketPath({'SWAYSOCK': '/a', 'I3SOCK': '/b'}), '/a');
    expect(swaySocketPath({'I3SOCK': '/b'}), '/b');
    expect(swaySocketPath({}), isNull);
    expect(swaySocketPath({'SWAYSOCK': ''}), isNull);
  });

  test('utf8 payload survives encode', () {
    final payload = jsonEncode(['workspace', 'window']);
    final decoded = SwayIpc.tryDecode(
      SwayIpc.encode(SwayIpc.subscribe, payload).toList(),
    )!;
    expect(jsonDecode(decoded.$2), ['workspace', 'window']);
  });
}
