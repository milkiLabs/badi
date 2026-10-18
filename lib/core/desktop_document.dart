import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'zig.g.dart';

/// One parsed `.desktop` document using the simplified parser
/// (Type/Name/Icon/Exec only). Wraps the native [BadiDocument] handle.
class DesktopDocument implements Finalizable {
  DesktopDocument._(this._lib, this._handle) {
    _finalizer.attach(this, _handle, detach: this);
  }

  final BadiLib _lib;
  final Pointer<BadiDocument> _handle;
  bool _disposed = false;
  late final Finalizer<Pointer<BadiDocument>> _finalizer =
      Finalizer((h) => _lib.badi_document_free(h));

  /// Parse [source] (the contents of a `.desktop` file).
  /// Throws [StateError] on parse/OOM failure.
  factory DesktopDocument.parse(String source, {required BadiLib lib}) {
    return using((arena) {
      final src = source.toNativeUtf8(allocator: arena);
      final handle = lib.badi_document_parse(src.cast());
      if (handle == nullptr) {
        throw StateError('badi_document_parse returned NULL');
      }
      return DesktopDocument._(lib, handle);
    });
  }

  String? get type => _field(_lib.badi_document_type(_handle));
  String? get name => _field(_lib.badi_document_name(_handle));
  String? get icon => _field(_lib.badi_document_icon(_handle));
  String? get exec => _field(_lib.badi_document_exec(_handle));

  String? _field(Pointer<Char> out) {
    if (out == nullptr) return null;
    final p = out.cast<Utf8>();
    final value = utf8.decode(
      p.cast<Uint8>().asTypedList(p.length),
      allowMalformed: true,
    );
    _lib.badi_free_string(out);
    return value;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    _lib.badi_document_free(_handle);
  }
}

/// A scanned list of `.desktop` documents from the standard application
/// directories, using the simplified parser.
class DesktopEntryList implements Finalizable {
  DesktopEntryList._(this._lib, this._handle) {
    _finalizer.attach(this, _handle, detach: this);
  }

  final BadiLib _lib;
  final Pointer<BadiDesktopList> _handle;
  bool _disposed = false;
  late final Finalizer<Pointer<BadiDesktopList>> _finalizer =
      Finalizer((h) => _lib.badi_desktop_list_free(h));

  /// Scan system + user application directories.
  /// Throws [StateError] on OOM.
  factory DesktopEntryList.scan({required BadiLib lib}) {
    final handle = lib.badi_desktop_scan();
    if (handle == nullptr) {
      throw StateError('badi_desktop_scan returned NULL');
    }
    return DesktopEntryList._(lib, handle);
  }

  int get length => _lib.badi_desktop_list_count(_handle);

  String? nameAt(int i) => _at(i, _lib.badi_desktop_list_name(_handle, i));
  String? typeAt(int i) => _at(i, _lib.badi_desktop_list_type(_handle, i));
  String? iconAt(int i) => _at(i, _lib.badi_desktop_list_icon(_handle, i));
  String? execAt(int i) => _at(i, _lib.badi_desktop_list_exec(_handle, i));

  String? _at(int i, Pointer<Char> out) {
    if (i < 0 || i >= length) return null;
    if (out == nullptr) return null;
    final p = out.cast<Utf8>();
    final value = utf8.decode(
      p.cast<Uint8>().asTypedList(p.length),
      allowMalformed: true,
    );
    _lib.badi_free_string(out);
    return value;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    _lib.badi_desktop_list_free(_handle);
  }
}
