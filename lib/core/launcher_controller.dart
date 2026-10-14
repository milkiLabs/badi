import 'dart:async';

import 'package:flutter/foundation.dart';

import 'actions.dart';
import 'batch.dart';
import 'session.dart';

/// Non-UI owner of picker state: session lifecycle, piped-stdin streaming,
/// filtering, and the selection cursor.
///
/// The widget layer renders this (via [ListenableBuilder]) and forwards
/// input; it keeps only text/scroll/focus controllers. Everything here is
/// plain Dart + [Session], so it is unit-testable with a fake
/// [LauncherActions] and injected session factories.
///
/// Session factories are required (no silent default): the UI wiring
/// passes real factories bound to the loaded library, tests pass fakes.
/// This keeps dynamic-library loading out of the core layer.
///
/// Lifecycle: create, call [attach()], then [detach()] + [dispose()].
/// [detach] stops streams and frees the session; async gaps check it so no
/// notification fires after detach.
class LauncherController extends ChangeNotifier {
  LauncherController({
    required this.actions,
    this.piped,
    required Session Function() openApps,
    required Session Function(String first) openLines,
  })  : _openApps = openApps,
        _openLines = openLines;

  final LauncherActions actions;

  /// Piped input lines; null selects the app launcher.
  final Stream<String>? piped;

  final Session Function() _openApps;
  final Session Function(String first) _openLines;

  Session? _session;
  int _count = 0;
  String? _error;
  bool _loading = true;
  int _selected = 0;
  String? _actionError;

  /// Pipe mode is event-driven: the first piped line flips it on.
  /// A dry pipe (flutter run, systemd, …) never produces, so the grace
  /// timer falls back to apps instead of hanging forever.
  bool _pipeMode = false;
  bool _streamDone = false;
  Timer? _grace;
  StreamSubscription<String>? _sub;
  Batcher<String>? _batcher;

  /// Last query text, re-applied when a slow pipe flips late (after the
  /// user already typed while the apps fallback was showing).
  String _lastQuery = '';

  bool _attached = false;

  int get count => _count;
  String? get error => _error;
  bool get loading => _loading;
  int get selected => _selected;
  String? get actionError => _actionError;
  bool get pipeMode => _pipeMode;
  bool get streamDone => _streamDone;

  /// Copy out shown row `i`. Only valid when `count > 0`.
  SessionRow rowAt(int i) => _session!.rowAt(i);

  /// Start: open the apps session immediately on a terminal, otherwise wait
  /// for the first piped line (grace timer rescues dry supervised stdin).
  void attach() {
    assert(!_attached);
    _attached = true;
    if (piped == null) {
      _enterApps(); // terminal: apps immediately, no subscription
      return;
    }
    // Pipe-ish stdin: wait for the first signal instead of assuming data.
    // Real pipes produce in milliseconds; the grace timer rescues dry
    // supervised stdin (which never EOFs) without stalling real input.
    _grace = Timer(const Duration(milliseconds: 200), _onGraceTimeout);
    _sub = piped!.listen(
      _onLine,
      onError: _onStreamError,
      onDone: () => _onStreamDone(),
    );
  }

  /// Stop streams/timers and free the session. No notifications after this.
  void detach() {
    if (!_attached) return;
    _attached = false;
    unawaited(_sub?.cancel());
    _sub = null;
    _grace?.cancel();
    _grace = null;
    _batcher = null; // drop leftovers: flushing here could notify mid-detach
    _session?.close();
    _session = null;
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }

  /// Re-filter, reset the cursor to the top.
  void setQuery(String text) {
    final s = _session;
    _lastQuery = text;
    if (s == null) return;
    s.setQuery(text);
    _count = s.length;
    _selected = 0;
    _notify();
  }

  /// Move the cursor, clamped to the view.
  void move(int delta) {
    if (_count == 0) return;
    _selected = (_selected + delta).clamp(0, _count - 1);
    _notify();
  }

  /// Point the cursor at row `i` (mouse hover), clamped to the view.
  /// No-op when empty or already there (avoids rebuild storms while the
  /// pointer sweeps across rows).
  void select(int i) {
    if (_count == 0) return;
    final next = i.clamp(0, _count - 1);
    if (next == _selected) return;
    _selected = next;
    _notify();
  }

  /// Activate row `i`: pipe mode prints the line, apps mode spawns the
  /// launch target. Failures surface as [actionError]; success exits inside
  /// the actions implementation.
  Future<void> activate(int i) async {
    final s = _session;
    if (s == null) return;
    if (_pipeMode) {
      try {
        await actions.completeWithLine(s.result(i));
      } catch (e) {
        _actionError = 'Failed to print selection: $e';
        _notify();
      }
      return;
    }
    try {
      await actions.completeWithApp(s.target(i));
    } catch (e) {
      _actionError = 'Failed to launch: $e';
      _notify();
    }
  }

  /// User aborted (Escape).
  void cancel() => actions.cancel(pipeMode: _pipeMode);

  /// One input line arrived. The first line decides pipe mode; the rest
  /// stream through the batcher. Also fires for slow pipes after the apps
  /// fallback already painted (late flip, same path).
  void _onLine(String line) {
    if (_pipeMode) {
      _batcher!.add(line);
      return;
    }
    _enterPipe(line);
  }

  /// Open the picker on the first piped line. Replaces the apps session on
  /// a late flip; re-applies any query typed meanwhile.
  void _enterPipe(String first) {
    _pipeMode = true;
    _grace?.cancel();
    _grace = null;
    try {
      final s = _openLines(first);
      _session?.close();
      _session = s;
      _batcher = Batcher<String>(
        size: 500,
        idle: const Duration(milliseconds: 100),
        onBatch: _onBatch,
      );
      final q = _lastQuery;
      if (q.isNotEmpty) s.setQuery(q);
      _count = s.length;
      _selected = 0;
      _loading = false;
      _notify();
    } catch (e) {
      _pipeMode = false; // back to a consistent state: no pipe session open
      unawaited(_sub?.cancel());
      _sub = null;
      _batcher = null;
      _loading = false;
      _error = '$e';
      _notify();
    }
  }

  /// Open the app launcher: terminal path, empty pipe at EOF, or grace
  /// timeout on a dry pipe. Keeps listening: slow-pipe data still flips
  /// to the picker via _onLine.
  void _enterApps() {
    try {
      final s = _openApps();
      _session?.close();
      _session = s;
      _count = s.length;
      _selected = 0;
      _loading = false;
      _notify();
    } catch (e) {
      _loading = false;
      _error = '$e';
      _notify();
    }
  }

  void _onGraceTimeout() {
    _grace = null;
    if (!_pipeMode) _enterApps();
  }

  /// One input batch arrived: extend the session, refresh the view.
  /// The cursor is untouched by appends (existing rows never move), so only
  /// counts sync.
  void _onBatch(List<String> batch) {
    final s = _session;
    if (s == null || !_attached) return;
    s.append(batch);
    _count = s.length;
    _notify();
  }

  void _onStreamError(Object _, StackTrace __) => _onStreamDone();

  Future<void> _onStreamDone() async {
    if (_sub == null) return; // error and done both fire: run once
    await _sub?.cancel();
    _sub = null;
    _grace?.cancel();
    _grace = null;
    _batcher?.close(); // flush leftovers through _onBatch
    _batcher = null;
    if (!_attached) return;
    if (!_pipeMode && _session == null) {
      _enterApps(); // EOF with zero data: show apps
      return;
    }
    _streamDone = true;
    _notify();
  }

  void _notify() {
    if (_attached) notifyListeners();
  }
}
