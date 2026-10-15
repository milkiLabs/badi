import 'package:badi/ui/prayer_settings_page.dart';
import 'package:badi/ui/prayer_timings_window.dart';
import 'package:layer_shell/layer_shell.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'popup_window.dart';

/// Anchored top-center so it opens right under the screen-centered clock.
const PopupWindowConfig clockPopupConfig = PopupWindowConfig(
  width: 420,
  height: 520,
  namespace: 'badi-clock-popup',
  anchorEdges: [LayerShellEdge.top],
);

/// Prayer timings popup shown when hovering the bar clock. The settings
/// icon pushes [PrayerSettingsPage] onto the popup's own navigator.
class ClockPopupContent extends StatelessWidget {
  const ClockPopupContent({super.key, this.onHoverChanged});

  /// Forwards hover from pushed routes (which sit outside the popup's
  /// MouseRegion) so the hide debounce does not close the popup.
  final ValueChanged<bool>? onHoverChanged;

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PrayerSettingsPage(onHoverChanged: onHoverChanged),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('مواقيت الصلاة', style: AppTextStyles.rowTitle),
            const Spacer(),
            IconButton(
              tooltip: "إعدادات مواقيت الصلاة",
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => _openSettings(context),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Expanded(child: PrayerTimingsScreen()),
      ],
    );
  }
}
