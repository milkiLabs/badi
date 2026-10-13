import 'dart:async';

/// Collects stream items into batches: flush every [size] items or after
/// [idle] of quiet, whichever first. Stdin firehoses (`find /`) flush on
/// size; dripping producers flush on the timer so the list stays live.
class Batcher<T> {
  Batcher({required this.size, required this.idle, required this.onBatch});

  final int size;
  final Duration idle;
  final void Function(List<T>) onBatch;

  final List<T> _buf = [];
  Timer? _timer;

  void add(T item) {
    _buf.add(item);
    if (_buf.length >= size) {
      _flush();
    } else {
      _timer ??= Timer(idle, _flush);
    }
  }

  /// Flush leftovers (call on stream done). Never calls back when empty.
  void close() {
    _flush();
  }

  void _flush() {
    _timer?.cancel();
    _timer = null;
    if (_buf.isEmpty) return;
    final batch = List<T>.of(_buf, growable: false);
    _buf.clear();
    onBatch(batch);
  }
}
