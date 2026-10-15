import 'package:material_ui/material_ui.dart';

import '../platform/sys_stats.dart';
import 'app_theme.dart';
import 'popup_window.dart';

/// Configuration for the system stats popup. Smaller than the wifi /
/// bluetooth popups: two usage rows, no interaction.
const PopupWindowConfig sysmonPopupConfig = PopupWindowConfig(
  width: 260,
  height: 176,
  namespace: 'badi-sysmon-popup',
);

/// Hover popup content for the bar's CPU/MEM chips: live percentages with
/// usage bars. Same [SysStatsService] instance as the bar chips, so no
/// extra polling.
class SysmonPopupContent extends StatefulWidget {
  const SysmonPopupContent({super.key});

  @override
  State<SysmonPopupContent> createState() => _SysmonPopupContentState();
}

class _SysmonPopupContentState extends State<SysmonPopupContent> {
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
    final memUsed = s.memTotalBytes != null && s.memAvailBytes != null
        ? '${formatBytes(s.memTotalBytes! - s.memAvailBytes!)}'
            ' / ${formatBytes(s.memTotalBytes!)}'
        : 'unavailable';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('System', style: AppTextStyles.rowTitle),
        const SizedBox(height: 8),
        _UsageRow(
          icon: Icons.speed,
          label: 'CPU',
          fraction: s.cpuFraction,
          detail: s.cpuFraction == null
              ? 'sampling...'
              : '${formatFraction(s.cpuFraction)} used',
        ),
        const SizedBox(height: 8),
        _UsageRow(
          icon: Icons.memory,
          label: 'MEM',
          fraction: s.memFraction,
          detail: memUsed,
        ),
      ],
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.icon,
    required this.label,
    required this.fraction,
    required this.detail,
  });

  final IconData icon;
  final String label;
  final double? fraction;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final color = fraction != null && fraction! > 0.85
        ? AppColors.error
        : AppColors.body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Text(label, style: AppTextStyles.body),
            const Spacer(),
            Text(
              formatFraction(fraction),
              style: AppTextStyles.rowTitle.copyWith(color: color),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: fraction ?? 0,
            minHeight: 6,
            backgroundColor: AppColors.selectedRow,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 2),
        Text(detail, style: AppTextStyles.rowSubtitle),
      ],
    );
  }
}
