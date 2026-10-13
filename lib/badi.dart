import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'zig.dart';
import 'zig.g.dart';

/// Owning handle for a `badi_scan` result (one entry per parsed .desktop file).
///
/// Items are accessed by index and must not outlive the list:
/// ```dart
/// final apps = BadiApps.scan();
/// try {
///   for (var i = 0; i < apps.length; i++) {
///     print(apps.getAt(i, 'Desktop Entry', 'Name'));
///   }
/// } finally {
///   apps.close();
/// }
/// ```
class BadiApps implements Finalizable {
  BadiApps._(this._lib, this._list) {
    _finalizer.attach(this, _list, detach: this);
  }

  final ZigLib _lib;
  final Pointer<BadiAppList> _list;
  bool _closed = false;
  late final Finalizer<Pointer<BadiAppList>> _finalizer =
      Finalizer((list) => _lib.badi_scan_destroy(list));

  /// Scan system + user applications dirs. `homeDir` locates
  /// `~/.local/share/applications`; defaults to `$HOME`.
  /// Throws [StateError] on OOM (NULL handle).
  factory BadiApps.scan({String? homeDir, ZigLib? lib}) {
    final l = lib ?? zigLib;
    final home = homeDir ?? Platform.environment['HOME'];
    return using((arena) {
      final h =
          home == null ? nullptr.cast<Utf8>() : home.toNativeUtf8(allocator: arena);
      final list = l.badi_scan(h.cast());
      if (list == nullptr) throw StateError('badi_scan returned NULL (OOM)');
      return BadiApps._(l, list);
    });
  }

  /// Number of parsed docs.
  int get length {
    _checkOpen();
    return _lib.badi_scan_count(_list);
  }

  /// Indexed lookup. Returns null when index/group/key is missing.
  String? getAt(int index, String group, String key, {String? locale}) {
    _checkOpen();
    return using((arena) {
      final g = group.toNativeUtf8(allocator: arena);
      final k = key.toNativeUtf8(allocator: arena);
      final l = locale == null
          ? nullptr.cast<Utf8>()
          : locale.toNativeUtf8(allocator: arena);
      final out = _lib.badi_scan_get_value(_list, index, g.cast(), k.cast(), l.cast());
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
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _finalizer.detach(this);
    _lib.badi_scan_destroy(_list);
  }

  void _checkOpen() {
    if (_closed) throw StateError('BadiApps already closed');
  }
}
