import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../platform/network_speed.dart';
import '../platform/sys_stats.dart';
import 'app_theme.dart';
import 'workspaces_indicator.dart';

class BarBody extends StatelessWidget {
  const BarBody({
    super.key,
    required this.onOpenLauncher,
    required this.onWifiTap,
    required this.onWifiHover,
    required this.onBluetoothTap,
    required this.onBluetoothHover,
    required this.onSysmonTap,
    required this.onSysmonPointer,
    required this.onClockTap,
    required this.onClockHover,
    required this.onPowerTap,
    required this.onPowerHover,
  });

  final VoidCallback onOpenLauncher;
  final VoidCallback onWifiTap;
  final ValueChanged<bool> onWifiHover;
  final VoidCallback onBluetoothTap;
  final ValueChanged<bool> onBluetoothHover;
  final VoidCallback onSysmonTap;
  final ValueChanged<bool> onSysmonPointer;
  final VoidCallback onClockTap;
  final ValueChanged<bool> onClockHover;
  final VoidCallback onPowerTap;
  final ValueChanged<bool> onPowerHover;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        // Stack so the clock is centered on the screen itself: the Row
        // holds the asymmetric left/right content, while the Align centers
        // the clock over the full bar width. Only the clock text hit-tests;
        // the Align is transparent to hover elsewhere. This also keeps the
        // clock fixed when the CPU/MEM labels change width (3% vs 22%).
        child: Stack(
          children: [
            // Fills the bar so the Row's default cross-axis centering
            // applies; without this the Row shrinks to content height and
            // sticks to the top of the Stack.
            Positioned.fill(
              child: Row(
                children: [
                  GestureDetector(
                    onTap: onOpenLauncher,
                    child: const MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Text('Badi', style: AppTextStyles.rowTitle),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const WorkspacesIndicator(),
                  const Spacer(),
                  MouseRegion(
                    onEnter: (_) => onSysmonPointer(true),
                    onExit: (_) => onSysmonPointer(false),
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onSysmonTap,
                      child: const SysStatsTray(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  MouseRegion(
                    onEnter: (_) => onWifiHover(true),
                    onExit: (_) => onWifiHover(false),
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onWifiTap,
                      child: const Icon(
                        Icons.wifi,
                        color: AppColors.body,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const NetworkSpeedLabel(),
                  const SizedBox(width: 10),
                  MouseRegion(
                    onEnter: (_) => onBluetoothHover(true),
                    onExit: (_) => onBluetoothHover(false),
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onBluetoothTap,
                      child: const Icon(
                        Icons.bluetooth,
                        color: AppColors.body,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  MouseRegion(
                    onEnter: (_) => onPowerHover(true),
                    onExit: (_) => onPowerHover(false),
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onPowerTap,
                      child: const Icon(
                        Icons.power_settings_new,
                        color: AppColors.body,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.center,
              child: MouseRegion(
                onEnter: (_) => onClockHover(true),
                onExit: (_) => onClockHover(false),
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onClockTap,
                  child: const ClockLabel(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// CPU + memory chips driven by [SysStatsService] (Zig snapshots via FFI).
/// Compact enough for the 32px bar: 14px icons + 11px text.
class SysStatsTray extends StatefulWidget {
  const SysStatsTray({super.key});

  @override
  State<SysStatsTray> createState() => _SysStatsTrayState();
}

class _SysStatsTrayState extends State<SysStatsTray> {
  final _service = SysStatsService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChange);
    _service.start();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_onChange);
    _service.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _service;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatChip(
          icon: Icons.speed,
          label: 'CPU',
          value: formatFraction(s.cpuFraction),
          alert: (s.cpuFraction ?? 0) > 0.85,
        ),
        const SizedBox(width: 10),
        _StatChip(
          icon: Icons.memory,
          label: 'MEM',
          value: formatFraction(s.memFraction),
          alert: (s.memFraction ?? 0) > 0.85,
        ),
      ],
    );
  }
}

/// Live download rate, sampled from the active default-route interface.
class NetworkSpeedLabel extends StatefulWidget {
  const NetworkSpeedLabel({super.key});

  @override
  State<NetworkSpeedLabel> createState() => _NetworkSpeedLabelState();
}

class _NetworkSpeedLabelState extends State<NetworkSpeedLabel> {
  final _service = NetworkSpeedService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChange);
    _service.start();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_onChange);
    _service.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
        formatNetworkSpeed(_service.bytesPerSecond),
        style: AppTextStyles.rowSubtitle,
      );
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.alert,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final color = alert ? AppColors.error : AppColors.body;
    // No Tooltip here: the bar surface is 32px tall and clips anything
    // overflowing it. Details live in the sysmon popup, which is
    // its own layer-shell surface (see sysmon_popup.dart).
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 4),
        Text(
          '$label $value',
          style: AppTextStyles.rowSubtitle.copyWith(color: color),
        ),
      ],
    );
  }
}

/// 12-hour clock for the center of the bar (e.g. "3:05 PM"). Ticks on
/// minute boundaries so the bar never shows a stale minute.
class ClockLabel extends StatefulWidget {
  const ClockLabel({super.key});

  @override
  State<ClockLabel> createState() => _ClockLabelState();
}

class _ClockLabelState extends State<ClockLabel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    final now = DateTime.now();
    final next =
        DateTime(now.year, now.month, now.day, now.hour, now.minute + 1);
    _timer = Timer(
      next.difference(now) + const Duration(milliseconds: 300),
      () {
        if (!mounted) return;
        setState(() {});
        _schedule();
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(formatClock(DateTime.now()), style: AppTextStyles.rowTitle);
  }
}

/// "3:05 PM" style 12-hour time, no leading zero on the hour.
String formatClock(DateTime t) {
  final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final mm = t.minute.toString().padLeft(2, '0');
  return '$h12:$mm ${t.hour < 12 ? 'AM' : 'PM'}';
}
