import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'zig.dart';
import 'zig.g.dart';

/// One shown row: an app or one piped line. [id] is the session-local row
/// to pass back to [Session.launch]/[Session.result].
class SessionRow {
  const SessionRow({
    required this.id,
    required this.title,
    this.subtitle,
    this.iconPath,
  });

  final int id;
  final String title;
  final String? subtitle;
  final String? iconPath;
}

/// Owning handle for a picker session. Filtering, selection, and launching
/// live in the Zig backend; this class only copies strings out and forwards
/// calls. Pipe mode and app mode share this one type:
/// ```dart
/// final s = Session.lines(['foo', 'bar']);
/// try {
///   s.setQuery('ba');
///   print(s.rowAt(s.selected).title); // bar
/// } finally {
///   s.close();
/// }
/// ```
class Session implements Finalizable {
  Session._(this._lib, this._handle) {
    _finalizer.attach(this, _handle, detach: this);
  }

  final ZigLib _lib;
  final Pointer<BadiSession> _handle;
  bool _closed = false;
  late final Finalizer<Pointer<BadiSession>> _finalizer =
      Finalizer((s) => _lib.badi_session_destroy(s));

  /// Scan system + user applications dirs, sorted by name.
  /// `locale` (defaults to the system locale) picks localized names.
  /// Throws [StateError] on OOM (NULL handle).
  factory Session.apps({String? locale, ZigLib? lib}) {
    final l = lib ?? zigLib;
    final lang = locale ?? Platform.localeName;
    return using((arena) {
      final loc = lang.toNativeUtf8(allocator: arena);
      final handle = l.badi_session_apps(loc.cast());
      if (handle == nullptr) {
        throw StateError('badi_session_apps returned NULL (OOM)');
      }
      return Session._(l, handle);
    });
  }

  /// Wrap piped input lines (copied; caller keeps ownership).
  /// Throws [StateError] on OOM (NULL handle).
  factory Session.lines(List<String> lines, {ZigLib? lib}) {
    final l = lib ?? zigLib;
    return using((arena) {
      final handle = lines.isEmpty
          ? l.badi_session_lines(
              nullptr.cast(), 0)
          : l.badi_session_lines(_toNativeLines(lines, arena), lines.length);
      if (handle == nullptr) {
        throw StateError('badi_session_lines returned NULL (OOM)');
      }
      return Session._(l, handle);
    });
  }

  /// Copy lines into arena-owned `char**` for one FFI call. The backend
  /// dupes everything synchronously, so the arena frees on return.
  static Pointer<Pointer<Char>> _toNativeLines(
      List<String> lines, Allocator arena) {
    final ptrs = arena<Pointer<Utf8>>(lines.length);
    for (var i = 0; i < lines.length; i++) {
      ptrs[i] = lines[i].toNativeUtf8(allocator: arena);
    }
    return ptrs.cast();
  }

  /// Re-filter on `query` (blank shows all) and reset selection to the top.
  /// Throws [StateError] on OOM.
  void setQuery(String query) {
    _checkOpen();
    return using((arena) {
      final q = query.toNativeUtf8(allocator: arena);
      if (_lib.badi_session_query(_handle, q.cast()) != 0) {
        throw StateError('badi_session_query failed (OOM)');
      }
    });
  }

  /// Shown row count.
  int get length {
    _checkOpen();
    return _lib.badi_session_count(_handle);
  }

  /// Copy out shown row `i`.
  SessionRow rowAt(int i) {
    _checkOpen();
    final title = _string(_lib.badi_session_title(_handle, i));
    if (title == null) throw StateError('no row at index $i');
    return SessionRow(
      id: i,
      title: title,
      subtitle: _string(_lib.badi_session_subtitle(_handle, i)),
      iconPath: _string(_lib.badi_session_icon(_handle, i)),
    );
  }

  /// Move selection by `delta` rows, clamped. No-op when empty.
  void move(int delta) {
    _checkOpen();
    _lib.badi_session_move(_handle, delta);
  }

  /// Selected shown-row index, or -1 when empty.
  int get selected {
    _checkOpen();
    return _lib.badi_session_selected(_handle);
  }

  /// Spawn row `i` and return immediately. Apps mode only.
  /// Throws [StateError] on failure (lines mode included: nothing to spawn).
  void launch(int i) {
    _checkOpen();
    final rc = _lib.badi_session_launch(_handle, i);
    if (rc != 0) throw StateError('badi_session_launch failed ($rc)');
  }

  /// Selected line in lines mode: print it to stdout. Apps mode has no
  /// result string and throws [StateError].
  String result(int i) {
    _checkOpen();
    final out = _string(_lib.badi_session_result(_handle, i));
    if (out == null) throw StateError('no result at index $i');
    return out;
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
    _lib.badi_session_destroy(_handle);
  }

  void _checkOpen() {
    if (_closed) throw StateError('Session already closed');
  }
}
