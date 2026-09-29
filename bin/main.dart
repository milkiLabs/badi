import 'dart:ffi';
import 'dart:io';

import '../gen/zig_lib.g.dart';

void main() {
  // Built with:
  //   zig build
  // from inside zig_lib/  ->  zig_lib/zig-out/lib/libzig_lib.so
  final candidates = [
    '${Directory.current.path}${Platform.pathSeparator}zig_lib'
        '${Platform.pathSeparator}zig-out'
        '${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}libzig_lib.so',
    // fallback: old single-file workflow (`zig build-lib ...` in project root)
    '${Directory.current.path}${Platform.pathSeparator}libzig_lib.so',
  ];

  String? libPath;
  for (final p in candidates) {
    if (File(p).existsSync()) {
      libPath = p;
      break;
    }
  }
  if (libPath == null) {
    stderr.writeln('Missing libzig_lib.so. Tried:');
    for (final p in candidates) {
      stderr.writeln('  $p');
    }
    stderr.writeln('Run: (cd zig_lib && zig build)');
    exit(1);
  }

  final lib = ZigLib(DynamicLibrary.open(libPath));

  final result = lib.add(40, 2);
  print('add(40, 2) = $result'); // expect 42
}
