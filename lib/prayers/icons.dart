import 'package:badi/prayers/schedule.dart';
import 'package:flutter/widgets.dart' show Color, IconData;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Single source for prayer icons + tints. Shared by the timetable card
/// and the countdown progress marker so the two can never drift apart.
({IconData icon, Color color}) prayerIconFor(PrayerEventId? id) => switch (id) {
      PrayerEventId.fajr => (
          icon: LucideIcons.sunMoon,
          color: const Color(0xFF7C6AAE),
        ),
      PrayerEventId.sunrise => (
          icon: LucideIcons.sunrise,
          color: const Color(0xFFE8823A),
        ),
      PrayerEventId.dhuhr => (
          icon: LucideIcons.sun,
          color: const Color(0xFFB8860B),
        ),
      PrayerEventId.asr => (
          icon: LucideIcons.cloudSun,
          color: const Color(0xFFD97A2B),
        ),
      PrayerEventId.maghrib => (
          icon: LucideIcons.sunset,
          color: const Color(0xFFC14A3A),
        ),
      PrayerEventId.isha => (
          icon: LucideIcons.moon,
          color: const Color(0xFF4A5AA8),
        ),
      null => (
          icon: LucideIcons.sun,
          color: const Color(0xFF757575),
        ),
    };

/// Medallion tint for a prayer row. Same hue for bg + fg by design.
Color prayerTintFor(PrayerEventId? id) => prayerIconFor(id).color;
