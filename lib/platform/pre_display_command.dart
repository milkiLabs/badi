import 'dart:convert';
import 'dart:io';

import '../core/piped_row.dart';

/// Applies a shell command to each piped line for its launcher preview.
/// The command receives one item on stdin; the original remains the result.
Stream<String> applyPreDisplayCommand(
  Stream<String> lines,
  String command,
) =>
    lines.asyncMap((line) async {
      final process = await Process.start(
        '/bin/sh',
        ['-c', command],
      );
      // Drain both output streams while sending input so a command cannot
      // block on a full stdout/stderr pipe.
      final stdout = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final stderr = process.stderr.drain<void>();
      process.stdin.add(utf8.encode('$line\n'));
      await process.stdin.close();
      final exitCode = await process.exitCode;
      final output = await stdout;
      await stderr;
      final display = exitCode == 0 ? _firstOutputLine(output) : line;
      return encodePipedRow(display, line);
    });

String _firstOutputLine(String output) {
  final newline = output.indexOf('\n');
  final line = newline < 0 ? output : output.substring(0, newline);
  return line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
}
