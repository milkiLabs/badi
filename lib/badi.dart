import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'zig.dart';
import 'zig.g.dart';

/// One installed application, copied out of a [BadiApps] handle.
class BadiApp {
  const BadiApp({
    required this.name,
    required this.exec,
    required this.argv,
    required this.terminal,
    this.icon,
    this.comment,
    this.keywords,
    this.path,
  });

  final String name;
  final String exec;
  final List<String> argv;
  final bool terminal;
  final String? icon;
  final String? comment;
  final String? keywords;
  final String? path;
}

/// Owning handle for an app scan. Read items out with [appAt]/[apps],
/// then [close]:
/// ```dart
/// final apps = BadiApps.scan();
/// try {
///   for (final app in apps.apps) print(app.name);
/// } finally {
///   apps.close();
/// }
/// ```
class BadiApps implements Finalizable {
  BadiApps._(this._lib, this._handle) {
    _finalizer.attach(this, _handle, detach: this);
  }

  final ZigLib _lib;
  final Pointer<BadiAppList> _handle;
  bool _closed = false;
  late final Finalizer<Pointer<BadiAppList>> _finalizer =
      Finalizer((apps) => _lib.badi_apps_destroy(apps));

  /// Scan system + user applications dirs. `homeDir` locates
  /// `~/.local/share/applications` (defaults to `$HOME`); `locale`
  /// (defaults to the system locale) picks localized names.
  /// Throws [StateError] on OOM (NULL handle).
  factory BadiApps.scan({String? homeDir, String? locale, ZigLib? lib}) {
    final l = lib ?? zigLib;
    final home = homeDir ?? Platform.environment['HOME'];
    final lang = locale ?? Platform.localeName;
    return using((arena) {
      final h =
          home == null ? nullptr.cast<Utf8>() : home.toNativeUtf8(allocator: arena);
      final loc = lang.toNativeUtf8(allocator: arena);
      final handle = l.badi_apps_scan(h.cast(), loc.cast());
      if (handle == nullptr) throw StateError('badi_apps_scan returned NULL (OOM)');
      return BadiApps._(l, handle);
    });
  }

  /// Number of apps.
  int get length {
    _checkOpen();
    return _lib.badi_apps_count(_handle);
  }

  /// Copy out one app by index.
  BadiApp appAt(int index) {
    _checkOpen();
    final name = _string(_lib.badi_apps_name(_handle, index));
    if (name == null) throw StateError('no app at index $index');
    return BadiApp(
      name: name,
      exec: _string(_lib.badi_apps_exec(_handle, index)) ?? '',
      argv: argvAt(index),
      terminal: _lib.badi_apps_is_terminal(_handle, index) == 1,
      icon: _string(_lib.badi_apps_icon(_handle, index)),
      comment: _string(_lib.badi_apps_comment(_handle, index)),
      keywords: _string(_lib.badi_apps_keywords(_handle, index)),
      path: _string(_lib.badi_apps_path(_handle, index)),
    );
  }

  /// Copy out every app.
  List<BadiApp> get apps => [for (var i = 0; i < length; i++) appAt(i)];

  /// Launch arguments for one app. Empty when index is bad.
  List<String> argvAt(int index) {
    _checkOpen();
    final argc = _lib.badi_apps_argc(_handle, index);
    if (argc < 0) return const [];
    return [
      for (var j = 0; j < argc; j++)
        if (_string(_lib.badi_apps_argv(_handle, index, j)) case final arg?)
          arg,
    ];
  }

  /// Decode one owned native string, freeing it. Null stays null.
  /// Malformed UTF-8 decodes with replacement characters instead of throwing.
  String? _string(Pointer<Char> out) {
    if (out == nullptr) return null;
    try {
      final p = out.cast<Utf8>();
      return utf8.decode(
        p.cast<Uint8>().asTypedList(p.length),
        allowMalformed: true,
      );
    } finally {
      _lib.badi_free_string(out);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _finalizer.detach(this);
    _lib.badi_apps_destroy(_handle);
  }

  void _checkOpen() {
    if (_closed) throw StateError('BadiApps already closed');
  }
}
