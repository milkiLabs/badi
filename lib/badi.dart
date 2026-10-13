import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'zig.dart';
import 'zig.g.dart';

/// One installed application. [index] is the handle-local id to pass
/// to [BadiApps.launch].
class BadiApp {
  const BadiApp({
    required this.index,
    required this.name,
    this.comment,
    this.iconPath,
  });

  final int index;
  final String name;
  final String? comment;
  final String? iconPath;
}

/// Owning handle for an app scan. The backend (Zig) owns listing,
/// sorting, icon lookup, search, and launching; this class only copies
/// strings out and forwards calls:
/// ```dart
/// final apps = BadiApps.scan();
/// try {
///   for (final app in apps.search('term')) print(app.name);
///   apps.launch(apps.search('firefox').first.index);
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

  /// Scan system + user applications dirs, sorted by name.
  /// `locale` (defaults to the system locale) picks localized names.
  /// Throws [StateError] on OOM (NULL handle).
  factory BadiApps.scan({String? locale, ZigLib? lib}) {
    final l = lib ?? zigLib;
    final lang = locale ?? Platform.localeName;
    return using((arena) {
      final loc = lang.toNativeUtf8(allocator: arena);
      final handle = l.badi_apps_scan(loc.cast());
      if (handle == nullptr) {
        throw StateError('badi_apps_scan returned NULL (OOM)');
      }
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
      index: index,
      name: name,
      comment: _string(_lib.badi_apps_comment(_handle, index)),
      iconPath: _string(_lib.badi_apps_icon_path(_handle, index)),
    );
  }

  /// Copy out every app, in sort order.
  List<BadiApp> get apps => [for (var i = 0; i < length; i++) appAt(i)];

  /// Apps matching `query` (blank matches all), in sort order.
  List<BadiApp> search(String query) {
    _checkOpen();
    return using((arena) {
      final q = query.toNativeUtf8(allocator: arena);
      final found = _lib.badi_apps_search(_handle, q.cast());
      if (found == nullptr) throw StateError('badi_apps_search returned NULL (OOM)');
      try {
        final n = _lib.badi_found_count(found);
        final out = <BadiApp>[];
        for (var k = 0; k < n; k++) {
          final i = _lib.badi_found_at(found, k);
          if (i < 0) throw StateError('bad match at $k');
          out.add(appAt(i));
        }
        return out;
      } finally {
        _lib.badi_found_destroy(found);
      }
    });
  }

  /// Spawn the app by index and return immediately. Terminal apps are
  /// wrapped by the backend. Throws [StateError] on failure.
  void launch(int index) {
    _checkOpen();
    final rc = _lib.badi_apps_launch(_handle, index);
    if (rc != 0) throw StateError('badi_apps_launch failed ($rc)');
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
