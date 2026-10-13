import 'dart:ffi';
import 'dart:io';

import 'zig.g.dart';

/// Loads the Zig dynamic library and returns generated [ZigLib] bindings.
///
/// Search order:
/// 1. Alongside the Flutter executable (`bundle/lib/`).
/// 2. Dev fallback: `zig_lib/zig-out/lib/` relative to the current
///    working directory (covers `flutter run` and `dart run`).
/// 3. Bare soname lookup (system loader path / RPATH).
ZigLib loadZigLib() => ZigLib(_openZigLib());

/// Cached app-wide instance. `DynamicLibrary.open` + symbol lookup only
/// happens once; every screen/widget shares the same [ZigLib].
/// Use this everywhere in the app instead of calling [loadZigLib] per widget.
ZigLib? _cached;
ZigLib get zigLib => _cached ??= loadZigLib();

/// Test/reset hook (e.g. in widget tests that substitute a fake).
// ignore: avoid_setters_without_getters
set zigLib(ZigLib lib) => _cached = lib;

const _fileName = 'libzig_lib.so';

DynamicLibrary _openZigLib() {
  final exeDir = File(Platform.resolvedExecutable).parent;
  for (final path in [
    // Flutter bundle layout: <bundle>/lib/libzig_lib.so.
    '${exeDir.path}/lib/$_fileName',
    // In case it sits next to the binary.
    '${exeDir.path}/$_fileName',
    // Dev fallback relative to cwd (project root when running
    // `flutter run`, `dart run`, `dart test`).
    File('zig_lib/zig-out/lib/$_fileName').absolute.path,
    File('../zig_lib/zig-out/lib/$_fileName').absolute.path,
  ]) {
    if (File(path).existsSync()) return DynamicLibrary.open(path);
  }

  // Last resort: let the OS loader resolve it (RPATH / system path).
  return DynamicLibrary.open(_fileName);
}
