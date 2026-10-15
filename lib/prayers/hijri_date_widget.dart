import 'package:badi/prayers/hirji.dart';
import 'package:material_ui/material_ui.dart';

/// Hijri date label. Stateless renderer: the caller passes wall-clock time,
/// the Maghrib boundary, and the manual day offset; rendering goes through
/// the shared [hijriLabel] helper (same source as the native payload).
class HijriDateWidget extends StatelessWidget {
  const HijriDateWidget({
    required this.now,
    required this.maghrib,
    required this.offset,
    super.key,
  });
  final DateTime now;
  final DateTime? maghrib;
  final int offset;

  @override
  Widget build(BuildContext context) {
    return Text(
      hijriLabel(
        now: now,
        maghrib: maghrib,
        offset: offset,
        languageCode: Localizations.localeOf(context).languageCode,
      ),
      style: Theme.of(context).textTheme.titleMedium,
    );
  }
}
