import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/zig.g.dart';
import 'zig.dart';

/// Polls the Zig network sampler while the top-bar label is mounted.
/// Interface discovery, counter reads, and rate calculation live in Zig.
class NetworkSpeedService extends ChangeNotifier {
  NetworkSpeedService._({BadiLib? lib}) : _libOverride = lib;

  static final NetworkSpeedService instance = NetworkSpeedService._();

  @visibleForTesting
  factory NetworkSpeedService.test(BadiLib lib) =>
      NetworkSpeedService._(lib: lib);

  final BadiLib? _libOverride;
  BadiLib get _lib => _libOverride ?? badiLib;

  static const pollInterval = Duration(seconds: 1);

  double? bytesPerSecond;
  int _users = 0;
  Timer? _timer;

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
    bytesPerSecond = null;
  }

  /// One synchronous sample. The first sample establishes Zig's baseline.
  void pollOnce() => _poll();

  void _poll() {
    final rate = _lib.badi_network_download_speed();
    bytesPerSecond = rate < 0 ? null : rate;
    notifyListeners();
  }
}

/// Compact download-rate label for the top bar.
String formatNetworkSpeed(double? bytesPerSecond) {
  if (bytesPerSecond == null) return '— KB/s';
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  return '${(bytesPerSecond / 1024).round()} KB/s';
}
