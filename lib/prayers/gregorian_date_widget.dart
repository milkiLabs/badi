import 'package:badi/prayers/inline_text.dart';
import 'package:badi/prayers/islamic_date.dart';
import 'package:badi/prayers/prayer_names.dart';
import 'package:material_ui/material_ui.dart';

/// Gregorian civil date label, flipped at Maghrib like the Hijri date and
/// the day name (Islamic day boundary), not at midnight.
///
/// Stateless renderer: the caller passes wall-clock time in the prayer
/// timezone plus the Maghrib boundary; the effective date goes through the
/// shared [islamicEffectiveDate] helper — the same source as [islamicWeekday]
/// and [hijriLabel] — so the three can never disagree. Maghrib rollover
/// arrives via the parent's rebuild (nudge timer fires at each prayer
/// boundary), so no timer lives here.
class GregorianDateWidget extends StatelessWidget {
  const GregorianDateWidget(
      {required this.now, required this.maghrib, super.key});
  final DateTime now;
  final DateTime? maghrib;

  @override
  Widget build(BuildContext context) {
    final effective = islamicEffectiveDate(now: now, maghrib: maghrib);
    return InlineTextWidget(
      style: Theme.of(context).textTheme.titleMedium,
      '${effective.day} ${gregorianMonthName(context, effective.month)} ${effective.year}',
    );
  }
}
