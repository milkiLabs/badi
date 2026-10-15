import 'package:material_ui/material_ui.dart';

import '../platform/sys_stats.dart';
import 'app_theme.dart';

class BarBody extends StatelessWidget {
  const BarBody({
    super.key,
    required this.onOpenLauncher,
    required this.onWifiHover,
    required this.onBluetoothHover,
    required this.onSysmonHover,
  });

  final VoidCallback onOpenLauncher;
  final ValueChanged<bool> onWifiHover;
  final ValueChanged<bool> onBluetoothHover;
  final ValueChanged<bool> onSysmonHover;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            GestureDetector(
              onTap: onOpenLauncher,
              child: const MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text('Badi', style: AppTextStyles.rowTitle),
              ),
            ),
            const Spacer(),
            MouseRegion(
              onEnter: (_) => onSysmonHover(true),
              onExit: (_) => onSysmonHover(false),
              cursor: SystemMouseCursors.basic,
              child: const SysStatsTray(),
            ),
            const SizedBox(width: 12),
            MouseRegion(
              onEnter: (_) => onWifiHover(true),
              onExit: (_) => onWifiHover(false),
              cursor: SystemMouseCursors.basic,
              child: const Icon(Icons.wifi, color: AppColors.body, size: 18),
            ),
            const SizedBox(width: 10),
            MouseRegion(
              onEnter: (_) => onBluetoothHover(true),
              onExit: (_) => onBluetoothHover(false),
              cursor: SystemMouseCursors.basic,
              child: const Icon(Icons.bluetooth, color: AppColors.body, size: 18),
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
    // overflowing it. Details live in the sysmon hover popup, which is
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
