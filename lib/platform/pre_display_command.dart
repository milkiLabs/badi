import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../core/piped_row.dart';

/// Runs one shell filter for the piped stream. The filter receives all input
/// rows on stdin and must emit one preview line per input row, in the same
/// order. The original row is retained for the selected result.
Stream<String> applyPreDisplayCommand(
  Stream<String> lines,
  String command,
) {
  final output = StreamController<String>();
  final pendingSources = Queue<String>();
  Process? process;

  Future<void> run() async {
    try {
      process = await Process.start('/bin/sh', ['-c', command]);
    } catch (_) {
      await for (final line in lines) {
        if (output.isClosed) return;
        output.add(encodePipedRow(line, line));
      }
      await output.close();
      return;
    }

    final child = process!;
    final stdoutDone = Completer<void>();
    final stderrDone = child.stderr.drain<void>();
    child.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
      (preview) {
        if (pendingSources.isEmpty || output.isClosed) return;
        output.add(encodePipedRow(preview, pendingSources.removeFirst()));
      },
      onError: (Object error, StackTrace stack) {
        if (!output.isClosed) output.addError(error, stack);
      },
      onDone: stdoutDone.complete,
    );

    try {
      await for (final line in lines) {
        if (output.isClosed) break;
        pendingSources.addLast(line);
        child.stdin.add(utf8.encode('$line\n'));
        await child.stdin.flush();
      }
      await child.stdin.close();
      await child.exitCode;
      await stdoutDone.future;
      await stderrDone;

      // If the filter emits fewer rows than it received, retain the
      // unpaired source rows instead of silently dropping them.
      while (pendingSources.isNotEmpty && !output.isClosed) {
        final line = pendingSources.removeFirst();
        output.add(encodePipedRow(line, line));
      }
      if (!output.isClosed) await output.close();
    } catch (error, stack) {
      child.kill();
      if (!output.isClosed) {
        output.addError(error, stack);
        await output.close();
      }
    }
  }

  output.onListen = () {
    unawaited(run());
  };
  output.onCancel = () {
    process?.kill();
  };
  return output.stream;
}
