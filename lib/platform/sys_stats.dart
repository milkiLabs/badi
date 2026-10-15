import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../core/zig.g.dart';
import 'zig.dart';

/// Polls CPU + memory snapshots from the Zig backend (`/proc` parsing and
/// delta math live in `badi_lib/src/sysmon.zig`; this layer only owns the
/// Timer, the previous CPU sample, and formatting-friendly state).
///
/// Follows the [WifiService] start/stop refcount pattern: polling only runs
/// while at least one widget is listening.
class SysStatsService extends ChangeNotifier {
  SysStatsService._({BadiLib? lib}) : _libOverride = lib;

  static final SysStatsService instance = SysStatsService._();

  /// Test hook: construct with a fake [BadiLib].
  @visibleForTesting
  factory SysStatsService.test(BadiLib lib) => SysStatsService._(lib: lib);

  final BadiLib? _libOverride;
  BadiLib get _lib {
    final o = _libOverride;
    if (o != null) return o;
    return badiLib;
  }

  double? cpuFraction;
  double? memFraction;
  int? memTotalBytes;
  int? memAvailBytes;
  bool available = false;
  String? error;

  int? _prevTotal;
  int? _prevIdle;
  int _users = 0;
  Timer? _timer;
  bool _polling = false;

  static const pollInterval = Duration(seconds: 2);

  void start() {
    if (_users++ > 0) return;
    _poll();
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  void stop() {
    if (_users <= 0) return;
    if (--_users > 0) return;
    _users = 0;
    _timer?.cancel();
    _timer = null;
  }

  /// One synchronous snapshot pair. Public for tests.
  void pollOnce() => _poll();

  void _poll() {
    if (_polling) return;
    _polling = true;
    try {
      using((arena) {
        final cpuOut = arena<BadiCpuSnapshot>();
        final cpuOk = _lib.badi_cpu_snapshot(cpuOut) == 0;

        final memOut = arena<BadiMemInfo>();
        final memOk = _lib.badi_mem_snapshot(memOut) == 0;

        if (cpuOk) {
          final prevTotal = _prevTotal;
          final prevIdle = _prevIdle;
          final curTotal = cpuOut.ref.total;
          final curIdle = cpuOut.ref.idle;
          if (prevTotal != null && prevIdle != null) {
            final prev = arena<BadiCpuSnapshot>()
              ..ref.total = prevTotal
              ..ref.idle = prevIdle;
            final usage = _lib.badi_cpu_usage_between(prev, cpuOut);
            if (usage >= 0) cpuFraction = usage.clamp(0.0, 1.0);
          }
          _prevTotal = curTotal;
          _prevIdle = curIdle;
        }

        if (memOk) {
          memFraction = memOut.ref.used_percent.clamp(0.0, 1.0);
          memTotalBytes = memOut.ref.total_bytes;
          memAvailBytes = memOut.ref.avail_bytes;
        }

        final ok = cpuOk || memOk;
        available = ok;
        error = ok ? null : 'System stats unavailable';
      });
    } catch (_) {
      available = false;
      error = 'System stats unavailable';
    } finally {
      _polling = false;
    }
    notifyListeners();
  }
}

/// "12%" or em dash when unknown.
String formatFraction(double? v) =>
    v == null ? '—' : '${(v * 100).round()}%';

/// "3.2/7.5 GiB" style short label for the memory tooltip.
String formatBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '$s ${units[u]}';
}
