import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sway_ipc.dart';
import 'wm_provider.dart';
import 'wm_workspace.dart';

/// Sway (and i3-compatible) backend over raw IPC.
///
/// Uses two socket styles: one-shot sockets for `GET_WORKSPACES` /
/// `RUN_COMMAND`, plus one long-lived socket for `SUBSCRIBE ["workspace",
/// "window"]`. Any event on that socket emits [changes]; [WmService]
/// refetches on each tick (debounced). Reconnects with backoff when the
/// compositor restarts.
class SwayProvider implements WmProvider {
  SwayProvider({String? socketPath, Map<String, String>? env})
      : _socketPath = socketPath ?? swaySocketPath(env);

  final String? _socketPath;

  final _changes = StreamController<void>.broadcast();

  Socket? _eventSocket;
  StreamSubscription<Uint8List>? _eventSub;
  final _eventBuf = <int>[];
  bool _subscribed = false;
  bool _disposed = false;
  int _startCount = 0;
  Timer? _retryTimer;

  @override
  String get id => 'sway';

  @override
  bool get available => _socketPath != null && _socketPath!.isNotEmpty;

  @override
  Stream<void> get changes => _changes.stream;

  String get _path {
    final p = _socketPath;
    if (p == null || p.isEmpty) throw StateError('sway socket not found');
    return p;
  }

  @override
  Future<List<WmWorkspace>> fetchWorkspaces() async {
    final raw = await swayRequest(_path, SwayIpc.getWorkspaces);
    return WmWorkspace.listFromSwayJson(jsonDecode(raw));
  }

  @override
  Future<void> start() async {
    if (_disposed) return;
    if (_startCount++ > 0) return;
    await _connectEvents();
  }

  @override
  Future<void> stop() async {
    if (_startCount <= 0) return;
    if (--_startCount > 0) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _closeEvents();
  }

  Future<void> _connectEvents() async {
    if (_disposed || _startCount <= 0) return;
    await _closeEvents();
    late final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(_path, type: InternetAddressType.unix),
        0,
      ).timeout(const Duration(seconds: 2));
    } catch (_) {
      _scheduleRetry();
      return;
    }
    _eventSocket = socket;
    _eventBuf.clear();
    _subscribed = false;

    _eventSub = socket.listen(
      _onEventData,
      onError: (_) => _scheduleRetry(),
      onDone: () => _scheduleRetry(),
      cancelOnError: true,
    );
    try {
      socket.add(
        SwayIpc.encode(SwayIpc.subscribe, jsonEncode(['workspace', 'window'])),
      );
      await socket.flush();
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _onEventData(Uint8List chunk) {
    _eventBuf.addAll(chunk);
    for (;;) {
      final decoded = SwayIpc.tryDecode(_eventBuf);
      if (decoded == null) return;
      final (type, payload, consumed) = decoded;
      _eventBuf.removeRange(0, consumed);
      if (!_subscribed) {
        // First frame is the SUBSCRIBE ack (`{"success":true}`).
        _subscribed = true;
        continue;
      }
      if ((type & SwayIpc.eventMask) == 0) continue;
      // Any workspace/window event may change occupancy or focus.
      // Validate it is JSON before notifying, so a corrupt frame never
      // triggers a pointless refetch storm.
      try {
        jsonDecode(payload);
      } catch (_) {
        continue;
      }
      if (!_changes.isClosed) _changes.add(null);
    }
  }

  void _scheduleRetry() {
    if (_disposed || _startCount <= 0) return;
    _retryTimer?.cancel();
    _closeEvents();
    // Compositor restarts are rare; a fixed 2s backoff is enough without
    // hammering a half-dead socket.
    _retryTimer = Timer(const Duration(seconds: 2), _connectEvents);
    // Surface the outage promptly so the bar can hide the indicator.
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _closeEvents() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _subscribed = false;
    _eventBuf.clear();
    try {
      await _eventSub?.cancel();
    } catch (_) {}
    _eventSub = null;
    try {
      await _eventSocket?.close();
    } catch (_) {}
    try {
      _eventSocket?.destroy();
    } catch (_) {}
    _eventSocket = null;
  }

  @override
  Future<bool> focusWorkspace(WmWorkspace workspace) async {
    final target = workspace.num != null
        ? 'workspace number ${workspace.num}'
        : 'workspace "${workspace.name.replaceAll('"', '\\"')}"';
    try {
      final raw = await swayRequest(_path, SwayIpc.runCommand, target);
      final decoded = jsonDecode(raw);
      if (decoded is List && decoded.isNotEmpty) {
        final first = decoded.first;
        if (first is Map && first['success'] == true) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _startCount = 0;
    _retryTimer?.cancel();
    unawaited(_closeEvents());
    unawaited(_changes.close());
  }
}
