import 'dart:ffi';
import 'dart:io';

import 'zig.g.dart';

/// Loads the Zig dynamic library and returns generated [ZigLib] bindings.
///
/// Search order on desktop (Linux/Windows):
/// 1. Alongside the Flutter executable (`bundle/lib/` on Linux).
/// 2. Dev fallback: `zig_lib/zig-out/lib/` relative to the current
///    working directory (covers `flutter run` and `dart run`).
/// 3. Bare soname lookup (system loader path / RPATH).
///
/// On mobile:
/// - Android: library is packaged from
///   `android/app/src/main/jniLibs/<abi>/libzig_lib.so`, so loading by
///   soname works.
ZigLib loadZigLib() => ZigLib(_openZigLib());

/// Cached app-wide instance. `DynamicLibrary.open` + symbol lookup only
/// happens once; every screen/widget shares the same [ZigLib].
/// Use this everywhere in the app instead of calling [loadZigLib] per widget.
ZigLib? _cached;
ZigLib get zigLib => _cached ??= loadZigLib();

/// Test/reset hook (e.g. in widget tests that substitute a fake).
// ignore: avoid_setters_without_getters
set zigLib(ZigLib lib) => _cached = lib;

DynamicLibrary _openZigLib() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libzig_lib.so');
  }

  final fileName = _libFileName();
  final candidates = <String>[
    // 1. Next to the running executable (flutter bundle layout:
    //    <bundle>/comp on Linux, <bundle>/lib/libzig_lib.so).
    ..._bundleCandidates(fileName),
    // 2. Dev fallback relative to cwd (project root when running
    //    `flutter run`, `dart run`, `dart test`).
    File('zig_lib/zig-out/lib/$fileName').absolute.path,
    File('../zig_lib/zig-out/lib/$fileName').absolute.path,
  ];

  for (final path in candidates) {
    if (File(path).existsSync()) {
      return DynamicLibrary.open(path);
    }
  }

  // 3. Last resort: let the OS loader resolve it (RPATH / system path).
  return DynamicLibrary.open(fileName);
}

String _libFileName() {
  if (Platform.isWindows) return 'zig_lib.dll';
  return 'libzig_lib.so'; // Linux + Android
}

List<String> _bundleCandidates(String fileName) {
  final exeDir = File(Platform.resolvedExecutable).parent;
  if (Platform.isLinux) {
    return [
      '${exeDir.path}/lib/$fileName', // flutter bundle layout
      '${exeDir.path}/$fileName', // in case it sits next to the binary
    ];
  }
  if (Platform.isWindows) {
    return ['${exeDir.path}/$fileName'];
  }
  return ['${exeDir.path}/$fileName'];
}
