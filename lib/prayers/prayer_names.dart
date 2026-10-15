import 'package:badi/prayers/schedule.dart';
import 'package:material_ui/material_ui.dart' show BuildContext;

/// Locale-aware display names for the prayer screen.
///
/// [prayerEventArabicName] remains the Arabic-source form used by payloads
/// and logs; widgets read through here so the timetable, countdown, and
/// accessibility labels all follow the UI locale together.
String prayerEventName(BuildContext context, PrayerEventId id) {
  return switch (id) {
    PrayerEventId.fajr => "الفجر",
    PrayerEventId.sunrise => "الشروق",
    PrayerEventId.dhuhr => "الظهر",
    PrayerEventId.asr => "العصر",
    PrayerEventId.maghrib => "المغرب",
    PrayerEventId.isha => "العشاء",
  };
}

/// Locale-aware weekday name for [DateTime.weekday] (Monday = 1 .. Sunday = 7).
String weekdayName(BuildContext context, int weekday) {
  return switch (weekday) {
    1 => "الإثنين",
    2 => "الثلاثاء",
    3 => "الأربعاء",
    4 => "الخميس",
    5 => "الجمعة",
    6 => "السبت",
    7 => "الأحد",
    _ => '...',
  };
}

/// Locale-aware Gregorian month name (1 .. 12).
String gregorianMonthName(BuildContext context, int month) {
  return switch (month) {
    1 => "يناير",
    2 => "فبراير",
    3 => "مارس",
    4 => "أبريل",
    5 => "مايو",
    6 => "يونيو",
    7 => "يوليو",
    8 => "أغسطس",
    9 => "سبتمبر",
    10 => "أكتوبر",
    11 => "نوفمبر",
    12 => "ديسمبر",
    _ => '...',
  };
}
