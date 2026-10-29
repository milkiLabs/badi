import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/actions.dart';

/// Which picker the launcher currently shows.
enum ShellRequestMode { apps, lines }

/// UI state for the long-lived shell: is the launcher visible, and what is
/// it showing? Pure state + in-memory line pipe; knows nothing about sockets
/// or layer-shell windows, so it is unit-testable.
///
/// Lifecycle per open: `openApps`/`openLines` (false when busy) ... user
/// picks or aborts ... `closeLauncher`. Lines input streams through
/// [appendLine] until [closeInput]; both are safe to call when closed.
class ShellController extends ChangeNotifier {
  bool _open = false;
  ShellRequestMode? _mode;
  LauncherActions? _actions;
  StreamController<dynamic>? _input;

  /// Bumped on every open so the launcher view can key its state per
  /// request even if a rebuild reuses the element.
  int _generation = 0;

  bool get launcherOpen => _open;
  ShellRequestMode? get mode => _mode;

  /// Completion handler for the visible launcher; non-null while open.
  LauncherActions? get currentActions => _actions;

  /// Lines input pipe; null in apps mode or while closed. Single-subscription:
  /// buffered until the launcher's controller attaches.
  Stream<dynamic>? get piped => _input?.stream;

  int get generation => _generation;

  /// Show the app launcher. Returns false when a picker is already open.
  bool openApps({required LauncherActions actions}) {
    if (_open) return false;
    _open = true;
    _mode = ShellRequestMode.apps;
    _actions = actions;
    _input = null;
    _generation++;
    notifyListeners();
    return true;
  }

  /// Show the dmenu-style lines picker. Returns false when busy.
  bool openLines({required LauncherActions actions}) {
    if (_open) return false;
    _open = true;
    _mode = ShellRequestMode.lines;
    _actions = actions;
    _input = StreamController<dynamic>();
    _generation++;
    notifyListeners();
    return true;
  }

  /// One input line arrived (lines mode). Ignored when not applicable.
  /// Deliberately does not notify: streaming input must not rebuild the
  /// shell; the launcher's own controller refreshes its view.
  void appendLine(String line) {
    final input = _input;
    if (!_open || input == null || input.isClosed) return;
    input.add(line);
  }

  /// Append one native batch to the lines stream.
  void appendLines(List<String> lines) {
    final input = _input;
    if (!_open || input == null || input.isClosed || lines.isEmpty) return;
    input.add(List<String>.unmodifiable(lines));
  }

  /// No more input is coming (client EOF). The launcher marks its stream
  /// done; an input-less lines request falls back to apps, matching the
  /// one-shot picker's empty-pipe behavior.
  void closeInput() {
    final input = _input;
    if (input == null || input.isClosed) return;
    unawaited(input.close());
  }

  /// Hide the launcher and drop the request. Idempotent: replies and
  /// disconnect handlers may all call it.
  void closeLauncher() {
    if (!_open) return;
    _open = false;
    _mode = null;
    _actions = null;
    final input = _input;
    _input = null;
    if (input != null && !input.isClosed) unawaited(input.close());
    notifyListeners();
  }
}
