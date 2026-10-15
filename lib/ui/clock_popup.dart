import 'package:layer_shell/layer_shell.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'popup_window.dart';

/// Configuration for the clock popup (placeholder for a future calendar).
/// Anchored top-center so it opens right under the screen-centered clock.
const PopupWindowConfig clockPopupConfig = PopupWindowConfig(
  width: 280,
  height: 200,
  namespace: 'badi-clock-popup',
  anchorEdges: [LayerShellEdge.top],
);

/// Placeholder popup shown when hovering the bar clock.
class ClockPopupContent extends StatelessWidget {
  const ClockPopupContent({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Calendar', style: AppTextStyles.rowTitle),
        SizedBox(height: 12),
        Expanded(
          child: Center(
            child: Text(
              'Calendar goes here',
              style: AppTextStyles.rowSubtitle,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }
}
