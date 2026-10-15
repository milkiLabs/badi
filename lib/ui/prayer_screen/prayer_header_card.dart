import 'package:badi/prayers/next_prayer_countdown.dart';
import 'package:badi/ui/prayer_screen/prayer_date_row.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Single header card: dates on top, location + countdown below, split by a
/// mosque-ornament separator. One background, one border, one rounding.
class PrayerHeaderCard extends StatelessWidget {
  const PrayerHeaderCard({super.key});

  @override
  Widget build(BuildContext context) {
    final line = prayerSeparatorColor(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PrayerDateRow(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: Container(height: 1.5, color: line)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(
                    LucideIcons.mosque,
                    size: 15,
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.8),
                  ),
                ),
                Expanded(child: Container(height: 1.5, color: line)),
              ],
            ),
          ),
          const NextPrayerCountdown(),
        ],
      ),
    );
  }
}
