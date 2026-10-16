import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sway_ipc.dart';
import 'sway_provider.dart';
import 'wm_provider.dart';
import 'wm_workspace.dart';

/// Bar-facing workspace state. Owns backend selection + polling, so widgets
/// only see [workspaces], [available] and [focus].
///
/// Backend selection is centralized in [createDefaultWmProvider]: Sway today
/// (via `$SWAYSOCK`), Hyprland/Niri tomorrow by adding one branch there.
/// Follows the [SysStatsService]/[WifiService] start/stop refcount pattern:
/// polling and event subscriptions only run while a widget listens.
class WmService extends ChangeNotifier {
  WmService._({WmProvider? provider}) : _providerOverride = provider;

  static final WmService instance = WmService._();

  /// Test hook: inject a fake [WmProvider].
  @visibleForTesting
  factory WmService.test(WmProvider provider) => WmService._(
        provider: provider,
      );

  final WmProvider? _providerOverride;
  WmProvider? _provider;

  List<WmWorkspace> workspaces = const [];
  bool available = false;
  String? backendId;
  String? error;

  int _users = 0;
  StreamSubscription<void>? _changesSub;
  Timer? _debounce;
  bool _fetching = false;
  bool _fetchAgain = false;
  bool _disposed = false;

  /// Workspaces worth showing in the bar: occupied ones, always including
  /// the focused one (so an empty focused desk never vanishes).
  List<WmWorkspace> get visibleWorkspaces => workspaces
      .where((w) => w.hasWindows || w.focused)
      .toList(growable: false);

  WmWorkspace? get focused {
    for (final w in workspaces) {
      if (w.focused) return w;
    }
    return null;
  }

  void start() {
    if (_disposed) return;
    if (_users++ > 0) return;
    _provider ??= _providerOverride ?? createDefaultWmProvider();
    final provider = _provider;
    if (provider == null || !provider.available) {
      available = false;
      backendId = null;
      error = 'No supported window manager found';
      // Defer so a widget calling start() inside initState never notifies
      // during build.
      scheduleMicrotask(notifyListeners);
      return;
    }
    backendId = provider.id;
    _changesSub = provider.changes.listen((_) => _scheduleFetch());
    unawaited(_startProvider(provider));
  }

  Future<void> _startProvider(WmProvider provider) async {
    try {
      await provider.start();
    } catch (_) {
      // Event subscription is best-effort; the snapshot below still works.
    }
    await refresh();
  }

  void stop() {
    if (_users <= 0) return;
    if (--_users > 0) return;
    _users = 0;
    _debounce?.cancel();
    _debounce = null;
    unawaited(_changesSub?.cancel());
    _changesSub = null;
    final provider = _provider;
    if (provider != null && provider != _providerOverride) {
      unawaited(provider.stop());
    } else if (provider != null) {
      unawaited(provider.stop());
    }
  }

  /// Immediate refetch. Public for pull-to-refresh / tests.
  Future<void> refresh() async {
    if (_fetching) {
      _fetchAgain = true;
      return;
    }
    _fetching = true;
    try {
      do {
        _fetchAgain = false;
        await _fetch();
      } while (_fetchAgain);
    } finally {
      _fetching = false;
    }
  }

  void _scheduleFetch() {
    if (_users == 0) return;
    _debounce?.cancel();
    // Sway bursts events on a single gesture (e.g. move → focus → tick);
    // coalesce them into one GET_WORKSPACES round-trip.
    _debounce = Timer(const Duration(milliseconds: 120), refresh);
  }

  Future<void> _fetch() async {
    final provider = _provider;
    if (provider == null || !provider.available) {
      available = false;
      error = 'No supported window manager found';
      notifyListeners();
      return;
    }
    try {
      final next = await provider.fetchWorkspaces();
      workspaces = next;
      available = true;
      error = null;
    } catch (_) {
      available = false;
      workspaces = const [];
      error = 'Window manager unavailable';
    }
    if (!_disposed) notifyListeners();
  }

  /// Ask the compositor to focus [workspace] (bar click). Returns success.
  Future<bool> focus(WmWorkspace workspace) async {
    final provider = _provider;
    if (provider == null) return false;
    final ok = await provider.focusWorkspace(workspace);
    if (ok) await refresh();
    return ok;
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    unawaited(_changesSub?.cancel());
    if (_provider != null && _provider != _providerOverride) {
      _provider!.dispose();
    }
    _provider = null;
    super.dispose();
  }
}

/// Picks the first usable backend. Order matters: Sway first while it is the
/// only implementation; append Hyprland/Niri checks here later without
/// touching widgets. `[env]` is injectable for tests.
WmProvider? createDefaultWmProvider([Map<String, String>? env]) {
  final swayPath = swaySocketPath(env);
  if (swayPath != null && swayPath.isNotEmpty) {
    return SwayProvider(socketPath: swayPath);
  }
  // TODO: Hyprland (HYPRLAND_INSTANCE_SIGNATURE), Niri, i3.
  return null;
}
