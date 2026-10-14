import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

class BarBody extends StatelessWidget {
  const BarBody({
    super.key,
    required this.onOpenLauncher,
    required this.onWifiHover,
  });

  final VoidCallback onOpenLauncher;
  final ValueChanged<bool> onWifiHover;

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
              onEnter: (_) => onWifiHover(true),
              onExit: (_) => onWifiHover(false),
              cursor: SystemMouseCursors.basic,
              child: const Icon(Icons.wifi, color: AppColors.body, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
