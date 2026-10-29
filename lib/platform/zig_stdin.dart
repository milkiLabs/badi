import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import '../core/zig.g.dart';
import 'zig.dart';

/// Process-wide stdin stream backed by Zig's native line reader and batcher.
/// The stream emits non-empty lists of lines, then closes at EOF.
Stream<List<String>> get zigStdinBatches =>
    (_stdin ??= _ZigStdin(badiLib)).batches;

_ZigStdin? _stdin;

class _ZigStdin {
  _ZigStdin(this._lib) {
    _callback = NativeCallable<BadiStdinCallbackFunction>.listener(_onBatch);
    if (_lib.badi_stdin_start(_callback.nativeFunction, nullptr) != 0) {
      _controller.addError(StateError('Could not start Zig stdin reader'));
      _controller.close();
    }
  }

  final BadiLib _lib;
  final _controller = StreamController<List<String>>();
  late final NativeCallable<BadiStdinCallbackFunction> _callback;

  Stream<List<String>> get batches => _controller.stream;

  void _onBatch(
    Pointer<Void> _,
    Pointer<Char> batch,
    int byteLength,
    int lineCount,
    int event,
  ) {
    try {
      if (byteLength > 0) {
        final bytes = batch.cast<Uint8>().asTypedList(byteLength);
        final lines = utf8.decode(bytes, allowMalformed: true).split('\n');
        if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
        if (lines.length == lineCount && lines.isNotEmpty) {
          _controller.add(List<String>.unmodifiable(lines));
        }
      }
    } finally {
      if (byteLength > 0) _lib.badi_stdin_batch_free(batch);
    }

    if (event == 1) {
      _controller.close();
    } else if (event < 0) {
      _controller.addError(StateError('Error reading stdin in Zig'));
      _controller.close();
    }
  }
}
