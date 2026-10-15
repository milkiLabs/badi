import 'package:badi/prayers/icons.dart';
import 'package:badi/prayers/inline_text.dart';
import 'package:badi/prayers/prayer_names.dart';
import 'package:badi/prayers/provider.dart';
import 'package:badi/prayers/schedule.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart' as intl; // Make sure intl package is imported

/// Timetable card. Renders the cached daily schedule; the highlighted row is
/// derived at build time by matching the prayer's id against the next
/// event (not the instant), so after Isha — when next is *tomorrow's* Fajr —
/// today's Fajr row stays highlighted. Rebuilds only on nudge/settings changes.
///
/// Each fard row shows a time-of-day tinted medallion; the next prayer's row
/// is highlighted. The prev → next progress bar lives under the countdown
/// in [NextPrayerCountdown], not here.
class PrayerTimingsCard extends ConsumerWidget {
  const PrayerTimingsCard({super.key});

  /// Fard spec: display order is Maghrib-first (Islamic day starts at Maghrib).
  static const List<(PrayerEventId, IconData)> _fardSpecs = [
    (PrayerEventId.maghrib, LucideIcons.sunset),
    (PrayerEventId.isha, LucideIcons.moon),
    (PrayerEventId.fajr, LucideIcons.sunMoon),
    (PrayerEventId.sunrise, LucideIcons.sunrise),
    (PrayerEventId.dhuhr, LucideIcons.sun),
    (PrayerEventId.asr, LucideIcons.cloudSun),
  ];

  /// Sunnah visuals: asset, icon, tint. Names come from localizations in
  /// [build] so the rows follow the UI locale.
  static const List<(String, IconData, int)> _sunnahAssets = [
    ('assets/imgs/sunnah_duha.png', LucideIcons.sun, 0xFFE8823A),
    ('assets/imgs/sunnah_midnight.png', LucideIcons.moonStar, 0xFF4A5AA8),
    ('assets/imgs/sunnah_last_third.png', LucideIcons.moonStar, 0xFF7C6AAE),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Null while unconfigured: setup prompt lives on the timings screen.
    final view = ref.watch(prayerViewProvider);
    final sunnahNames = ["الضحى", "منتصف الليل", "الثلث الأخير من الليل"];
    if (view == null) {
      return _buildPlaceholderTable(context, sunnahNames);
    }
    final schedule = view.schedule;
    final nextId = view.next.id;
    final sunnah = schedule.sunnah;

    DateTime? at(PrayerEventId id) => schedule.events[id]?.time;
    final fardPrayers = [
      for (final (id, icon) in _fardSpecs)
        _PrayerTime(prayerEventName(context, id), at(id), id: id, icon: icon),
    ];

    final sunnahTimes = [
      sunnah?.duha,
      sunnah?.middleOfNight,
      sunnah?.lastThirdOfNight
    ];
    final sunnahPrayers = [
      for (var i = 0; i < _sunnahAssets.length; i++)
        _PrayerTime(
          sunnahNames[i],
          sunnahTimes[i],
          isSunnah: true,
          assetPath: _sunnahAssets[i].$1,
          icon: _sunnahAssets[i].$2,
          tint: Color(_sunnahAssets[i].$3),
        ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildCard(context, fardPrayers, nextId),
        const SizedBox(height: 8),
        _buildCard(context, sunnahPrayers, nextId),
      ],
    );
  }

  Widget _buildCard(
    BuildContext context,
    List<_PrayerTime> prayers,
    PrayerEventId? nextId,
  ) {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < prayers.length; i++) ...[
              _buildRow(
                context,
                prayers[i],
                isNext: prayers[i].id != null && prayers[i].id == nextId,
              ),
              if (i != prayers.length - 1)
                Divider(
                  height: 1,
                  indent: 64,
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: 0.15),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // --- REFACTORED: This is now a "dumb" builder method ---
  // It receives all the data it needs and contains NO reactive code.
  Widget _buildRow(
    BuildContext context,
    _PrayerTime prayer, {
    required bool isNext,
  }) {
    final rowColor = isNext
        ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3)
        : null;
    final medallion = prayer.tint ?? prayerTintFor(prayer.id);
    final hasVisual = prayer.icon != null || prayer.assetPath != null;

    return Container(
      decoration: BoxDecoration(color: rowColor),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          if (hasVisual)
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: medallion.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: prayer.assetPath != null
                    ? Image.asset(
                        prayer.assetPath!,
                        width: 22,
                        height: 22,
                        color: medallion,
                        colorBlendMode: BlendMode.srcIn,
                        semanticLabel: prayer.name,
                        // New files need a full restart (not hot reload) to
                        // enter the asset bundle; fall back to the Lucide
                        // icon instead of the red broken-image box.
                        errorBuilder: (context, error, stackTrace) => Icon(
                          prayer.icon,
                          size: 20,
                          color: medallion,
                          semanticLabel: prayer.name,
                        ),
                      )
                    : Icon(
                        prayer.icon,
                        size: 20,
                        color: medallion,
                        semanticLabel: prayer.name,
                      ),
              ),
            ),
          if (hasVisual) const SizedBox(width: 10),
          Expanded(
            child: InlineTextWidget(
              prayer.name,
              style: TextStyle(
                fontSize: 16,
                fontWeight: isNext
                    ? FontWeight.bold
                    : (prayer.isSunnah ? FontWeight.w500 : FontWeight.w600),
              ),
              textAlign: TextAlign.start,
            ),
          ),
          InlineTextWidget(
            _formatTime(context, prayer.time),
            style: const TextStyle(
              fontSize: 16,
              fontFamily: 'monospace',
              fontWeight: FontWeight.normal,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // Helper method to build the placeholder table to avoid code duplication
  Widget _buildPlaceholderTable(
    BuildContext context,
    List<String> sunnahNames,
  ) {
    final fardPrayers = [
      for (final (id, icon) in _fardSpecs)
        _PrayerTime(prayerEventName(context, id), null, id: id, icon: icon),
    ];
    final sunnahPrayers = [
      for (var i = 0; i < _sunnahAssets.length; i++)
        _PrayerTime(
          sunnahNames[i],
          null,
          isSunnah: true,
          assetPath: _sunnahAssets[i].$1,
          icon: _sunnahAssets[i].$2,
          tint: Color(_sunnahAssets[i].$3),
        ),
    ];

    // No next prayer while unconfigured: null matches nothing (sunnah rows
    // have null id, fard rows never have null next).
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildCard(context, fardPrayers, null),
        const SizedBox(height: 8),
        _buildCard(context, sunnahPrayers, null),
      ],
    );
  }

  String _formatTime(BuildContext context, DateTime? time) {
    if (time == null) {
      return '--:--';
    }

    // Format using intl package for 12-hour format (hh:mm)
    final timeFormatted = intl.DateFormat('hh:mm').format(time);
    final period = (time.hour >= 12) ? "م" : "ص";

    return '$timeFormatted $period';
  }
}

class _PrayerTime {
  const _PrayerTime(
    this.name,
    this.time, {
    this.isSunnah = false,
    this.id,
    this.icon,
    this.assetPath,
    this.tint,
  });
  final String name;
  final DateTime? time;
  final bool isSunnah;
  final PrayerEventId? id;
  final IconData? icon;
  final String? assetPath;
  final Color? tint;
}
