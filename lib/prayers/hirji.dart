import 'package:badi/prayers/islamic_date.dart' show islamicEffectiveDate;
import 'package:hijri/hijri_calendar.dart';

/// Display label for a Hijri date with manual day [offset], taking the
/// Maghrib-based Islamic day boundary into account. Pure: no prefs, no clock.
///
/// Single source for Hijri rendering: the in-app widget and the native
/// notification payload both go through here, so they can never disagree.
String hijriLabel({
  required DateTime now,
  required DateTime? maghrib,
  required int offset,
  String languageCode = 'ar',
}) {
  // The native payload shares this helper without a UI locale, so it keeps
  // the Arabic default; the widget passes the UI locale explicitly.
  HijriCalendar.setLocal(languageCode == 'en' ? 'en' : 'ar');
  final effective = islamicEffectiveDate(now: now, maghrib: maghrib).add(
    Duration(days: offset),
  );
  final cal = HijriCalendar.fromDate(effective);
  // The `hijri` package uses masculine ordinal names — display the
  // conventional forms: "ربيع الآخر"، "جمادى الأولى"، "جمادى الآخرة".
  const monthFixes = {
    'ربيع الثاني': 'ربيع الآخر',
    'جمادى الأول': 'جمادى الأولى',
    'جمادى الثاني': 'جمادى الآخرة',
  };
  final month = monthFixes[cal.longMonthName] ?? cal.longMonthName;
  return '${cal.hDay} $month ${cal.hYear}';
}
