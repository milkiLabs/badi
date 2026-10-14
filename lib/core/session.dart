import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'zig.g.dart';

/// One shown row: an app or one piped line. [id] is the session-local row
/// to pass back to [Session.target]/[Session.result].
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

/// What to spawn for one apps-mode row. Plain data: any frontend can
/// construct or consume this without touching the session handle.
class LaunchTarget {
  const LaunchTarget({
    required this.argv,
    required this.terminal,
    this.cwd,
  });

  /// Launch arguments (`Exec` expanded, field codes resolved).
  final List<String> argv;

  /// Whether to wrap in a terminal emulator (`Terminal=true`).
  final bool terminal;

  /// Working directory (`Path=`), or null to inherit.
  final String? cwd;
}

/// Owning handle for a picker session. Filtering lives in the Zig backend;
/// the selection cursor and spawning live here, in the frontend. Pipe mode
/// and app mode share this one type:
///
/// The [ZigLib] bindings are required explicitly so this layer never
/// locates the dynamic library itself (loading is platform wiring, see
/// `platform/zig.dart`).
/// ```dart
/// final s = Session.lines(['foo', 'bar'], lib: myLib);
/// try {
///   s.setQuery('ba');
///   print(s.rowAt(0).title); // bar
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
  factory Session.apps({String? locale, required ZigLib lib}) {
    final lang = locale ?? Platform.localeName;
    return using((arena) {
      final loc = lang.toNativeUtf8(allocator: arena);
      final handle = lib.badi_session_apps(loc.cast());
      if (handle == nullptr) {
        throw StateError('badi_session_apps returned NULL (OOM)');
      }
      return Session._(lib, handle);
    });
  }

  /// Wrap piped input lines (copied; caller keeps ownership).
  /// Throws [StateError] on OOM (NULL handle).
  factory Session.lines(List<String> lines, {required ZigLib lib}) {
    return using((arena) {
      final handle = lines.isEmpty
          ? lib.badi_session_lines(
              nullptr.cast(), 0)
          : lib.badi_session_lines(_toNativeLines(lines, arena), lines.length);
      if (handle == nullptr) {
        throw StateError('badi_session_lines returned NULL (OOM)');
      }
      return Session._(lib, handle);
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

  /// Append piped lines (copied). Lines mode only; throws [StateError]
  /// otherwise or on OOM. Empty input is a no-op. Newcomers matching the
  /// active query join the view; existing rows never move, so a
  /// frontend-owned cursor stays valid.
  void append(List<String> lines) {
    _checkOpen();
    if (lines.isEmpty) return;
    return using((arena) {
      if (_lib.badi_session_append(
              _handle, _toNativeLines(lines, arena), lines.length) !=
          0) {
        throw StateError('badi_session_append failed');
      }
    });
  }

  /// Re-filter on `query` (blank shows all). The caller owns the cursor
  /// and resets it after calling this.
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

  /// Launch target for shown row `i` (argv, terminal flag, working dir).
  /// Apps mode only; throws [StateError] when the row is bad, not
  /// launchable (lines mode), or a getter fails.
  LaunchTarget target(int i) {
    _checkOpen();
    final term = _lib.badi_session_is_terminal(_handle, i);
    if (term < 0) throw StateError('no launch target at index $i');
    final argc = _lib.badi_session_arg_count(_handle, i);
    final argv = <String>[];
    for (var a = 0; a < argc; a++) {
      final arg = _string(_lib.badi_session_arg(_handle, i, a));
      if (arg == null) throw StateError('missing argv $a at index $i');
      argv.add(arg);
    }
    return LaunchTarget(
      argv: argv,
      terminal: term > 0,
      cwd: _string(_lib.badi_session_cwd(_handle, i)),
    );
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
