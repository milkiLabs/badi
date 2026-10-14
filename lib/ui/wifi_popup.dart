import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

/// Simple Wi‑Fi status popup shown under the bar's wifi icon.
class WifiPopup extends StatelessWidget {
  const WifiPopup({super.key, required this.onHoverChanged});

  final ValueChanged<bool> onHoverChanged;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: Material(
        color: AppColors.background,
        child: Container(
          width: 220,
          height: 140,
          decoration: BoxDecoration(
            color: AppColors.row,
            border: Border.all(color: AppColors.hint, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Wi-Fi', style: AppTextStyles.rowTitle),
              const SizedBox(height: 8),
              Text('Network: ExampleSSID', style: AppTextStyles.body),
              const SizedBox(height: 4),
              Text('Signal: ▂▄▆█ Excellent', style: AppTextStyles.rowSubtitle),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {},
                    child: const Text('Settings'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
