import 'package:flutter_test/flutter_test.dart';
import 'package:zig_fii/core/batch.dart';

void main() {
  test('flushes every size items', () {
    final out = <List<int>>[];
    final b = Batcher<int>(
        size: 3, idle: const Duration(seconds: 10), onBatch: out.add);
    b.add(1);
    b.add(2);
    expect(out, isEmpty);
    b.add(3);
    expect(out, [
      [1, 2, 3]
    ]);
  });

  test('close flushes leftovers once', () {
    final out = <List<int>>[];
    final b = Batcher<int>(
        size: 100, idle: const Duration(seconds: 10), onBatch: out.add);
    b.add(1);
    b.add(2);
    b.close();
    b.close();
    expect(out, [
      [1, 2]
    ]);
  });

  test('idle flush keeps slow streams live', () async {
    final out = <List<int>>[];
    final b = Batcher<int>(
        size: 100, idle: const Duration(milliseconds: 5), onBatch: out.add);
    b.add(1);
    expect(out, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(out, [
      [1]
    ]);
  });
}
