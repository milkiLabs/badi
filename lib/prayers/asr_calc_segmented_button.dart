import 'package:badi/prayers/schedule.dart';
import 'package:material_ui/material_ui.dart';

/// Controlled madhab segmented button: [value] + [onChanged].
class AsrCalcSegmentedButton extends StatelessWidget {
  const AsrCalcSegmentedButton({
    required this.value,
    required this.onChanged,
    super.key,
  });
  final String value;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = value == PrayerMadhabs.hanafi
        ? PrayerMadhabs.hanafi
        : PrayerMadhabs.shafi;
    return Column(
      children: [
        Text(
          "حساب العصر على المذهب",
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment<String>(
              value: PrayerMadhabs.hanafi,
              label: Text("الحنفى"),
            ),
            ButtonSegment<String>(
              value: PrayerMadhabs.shafi,
              label: Text("الشافعى"),
            ),
          ],
          selected: <String>{selected},
          onSelectionChanged: (v) => onChanged(v.first),
        ),
      ],
    );
  }
}
