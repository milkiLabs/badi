import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'popup_window.dart';

/// Configuration for the Wi-Fi popup.
const PopupWindowConfig wifiPopupConfig = PopupWindowConfig(
  width: 220,
  height: 140,
  namespace: 'badi-wifi-popup',
);

/// Wi‑Fi popup content widget (stateless, just UI).
class WifiPopupContent extends StatelessWidget {
  const WifiPopupContent({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
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
              child: ElevatedButton(
                child: Text("Settings"),
                onPressed: () => {
                  print("hello"),
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
