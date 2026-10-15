import 'package:badi/prayers/gregorian_date_widget.dart';
import 'package:badi/prayers/hijri_date_widget.dart';
import 'package:badi/prayers/prayer_names.dart';
import 'package:badi/prayers/provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// Shared separator style for the prayer header: the Hijri|Gregorian divider
/// and the dates/countdown divider use the same color and weight.
Color prayerSeparatorColor(BuildContext context) =>
    Theme.of(context).colorScheme.outline.withValues(alpha: 0.45);

/// Day name + Hijri | Gregorian dates (all flip at Maghrib).
///
/// Pure derivation: weekday, Hijri label, and Gregorian date all come from
/// the watched [prayerViewProvider] plus wall-clock time at build, sharing
/// the same Maghrib-based Islamic day boundary. Rebuilds on nudge/settings
/// changes; keeps no timers of its own.
class PrayerDateRow extends ConsumerWidget {
  const PrayerDateRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final view = ref.watch(prayerViewProvider);
    final offset = ref.watch(hijriOffsetProvider);

    final now = view?.today ?? DateTime.now();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---- Day name line (in place of the old location line) ----
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  view == null ? '...' : weekdayName(context, view.weekday),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 2),
              // IconButton(
              //   tooltip: "شرح اليوم الإسلامي",
              //   iconSize: 19,
              //   visualDensity: VisualDensity.compact,
              //   padding: EdgeInsets.zero,
              //   constraints: const BoxConstraints(
              //     minWidth: 32,
              //     minHeight: 32,
              //   ),
              //   icon: Icon(
              //     Icons.info_outline,
              //     color: theme.colorScheme.primary.withValues(alpha: 0.75),
              //   ),
              //   // onPressed: () => showIslamicDayExplainer(context),
              // ),
            ],
          ),
          const SizedBox(height: 8),
          // ---- Dates row: Hijri | Gregorian ----
          Row(
            children: [
              Expanded(
                child: Center(
                  child: HijriDateWidget(
                    now: now,
                    maghrib: view?.schedule.maghrib,
                    offset: offset,
                  ),
                ),
              ),
              Container(
                width: 1.5,
                height: 28,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: prayerSeparatorColor(context),
              ),
              Expanded(
                child: Center(
                  child: GregorianDateWidget(
                    now: now,
                    maghrib: view?.schedule.maghrib,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
