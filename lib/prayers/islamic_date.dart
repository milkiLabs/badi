/// Islamic-day helpers: the Islamic day starts at Maghrib, not midnight.
DateTime islamicEffectiveDate({
  required DateTime now,
  required DateTime? maghrib,
}) {
  if (maghrib != null && now.isAfter(maghrib)) {
    return now.add(const Duration(days: 1));
  }
  return now;
}

/// Weekday of the current Islamic day (Monday=1..Sunday=7).
int islamicWeekday({
  required DateTime now,
  required DateTime? maghrib,
}) =>
    islamicEffectiveDate(now: now, maghrib: maghrib).weekday;
