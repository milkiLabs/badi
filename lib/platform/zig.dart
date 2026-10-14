import 'dart:ffi';
import 'dart:io';

import '../core/zig.g.dart';

/// Loads the Badi native library and returns generated [BadiLib] bindings.
///
/// Search order:
/// 1. Alongside the Flutter executable (`bundle/lib/`).
/// 2. Dev fallback: `badi_lib/zig-out/lib/` relative to the current
///    working directory (covers `flutter run` and `dart run`).
/// 3. Bare soname lookup (system loader path / RPATH).
BadiLib loadBadiLib() => BadiLib(_openBadiLib());

/// Cached app-wide instance. `DynamicLibrary.open` + symbol lookup only
/// happens once; every screen/widget shares the same [BadiLib].
/// Use this everywhere in the app instead of calling [loadBadiLib] per widget.
BadiLib? _cached;
BadiLib get badiLib => _cached ??= loadBadiLib();

/// Test/reset hook (e.g. in widget tests that substitute a fake).
// ignore: avoid_setters_without_getters
set badiLib(BadiLib lib) => _cached = lib;

const _fileName = 'libbadi.so';

DynamicLibrary _openBadiLib() {
  final exeDir = File(Platform.resolvedExecutable).parent;
  for (final path in [
    // Flutter bundle layout: <bundle>/lib/libbadi.so.
    '${exeDir.path}/lib/$_fileName',
    // In case it sits next to the binary.
    '${exeDir.path}/$_fileName',
    // Dev fallback relative to cwd (project root when running
    // `flutter run`, `dart run`, `dart test`).
    File('badi_lib/zig-out/lib/$_fileName').absolute.path,
    File('../badi_lib/zig-out/lib/$_fileName').absolute.path,
  ]) {
    if (File(path).existsSync()) return DynamicLibrary.open(path);
  }

  // Last resort: let the OS loader resolve it (RPATH / system path).
  return DynamicLibrary.open(_fileName);
}
