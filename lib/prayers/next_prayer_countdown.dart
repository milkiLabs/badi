import 'dart:async';
import 'package:badi/prayers/icons.dart';
import 'package:badi/prayers/prayer_names.dart';
import 'package:badi/prayers/provider.dart';
import 'package:badi/prayers/repository.dart';
import 'package:badi/prayers/schedule.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'dart:math' as math;

/// Countdown to the next prayer.
///
/// Owns its own 1-second [Timer] while mounted: navigating away disposes it,
/// so no Dart wakeups happen while the user reads elsewhere. The displayed
/// next prayer is derived live on every tick from the cached daily schedule
/// and wall-clock time — nothing about "now" is stored, so manual
/// system-clock changes correct themselves within a second with no refresh
/// protocol. When the derived next prayer differs from the last published
/// one, the tick pokes [prayerNudgeProvider] so highlight/weekday/date
/// widgets rebuild too.
class NextPrayerCountdown extends ConsumerStatefulWidget {
  const NextPrayerCountdown({super.key});

  @override
  ConsumerState<NextPrayerCountdown> createState() =>
      _NextPrayerCountdownState();
}

class _NextPrayerCountdownState extends ConsumerState<NextPrayerCountdown> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  /// Epoch-ms of the next event we last poked for. Change detection only —
  /// the display always uses the live derivation in [build].
  int? _pokedFor;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    final view = ref.read(prayerViewProvider);
    // Unconfigured: nothing to count toward. The `watch` in `build`
    // rebuilds us when settings get published — no ticking needed.
    if (view == null) return;
    final now = DateTime.now();
    // Single snapshot: one resolution per tick.
    final epoch = PrayerRepository.instance
        .snapshot(view.settings, now)
        ?.next
        .time
        .millisecondsSinceEpoch;
    if (epoch != _pokedFor) {
      _pokedFor = epoch;
      ref.read(prayerNudgeProvider.notifier).poke();
    }
    setState(() => _now = now);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final view = ref.watch(prayerViewProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: view == null
          ? _UnsetContent(onTap: () => _openSettings(context))
          : Builder(
              builder: (context) {
                // Live derivation, deliberately `read` (not `watch`): this
                // rebuild already runs every tick and on every nudge, so
                // subscribing would add nothing but rebuild loops.
                // One snapshot for next; progress shares the warm cache.
                final snap = PrayerRepository.instance.snapshot(
                  view.settings,
                  _now,
                );
                final next = snap?.next;
                if (next == null) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _LocationLine(
                        label: view.cityLabel,
                        isUnset: view.cityLabel.isEmpty,
                        onTap: () => _openSettings(context),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "خطأ في تحميل مواقيت الصلاة.",
                        style: const TextStyle(fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  );
                }
                // `next` is strictly after `_now` by construction
                // (`nextAt` returns the first event after now), so this stays
                // positive through the midnight→Fajr window. Clamped
                // defensively so a clock jump can never render negative.
                final rawLeft = next.time.difference(_now);
                final left = rawLeft.isNegative ? Duration.zero : rawLeft;
                // Timeline query (prev … now … next): stays visible through
                // the midnight→Fajr window. The widget never thinks in
                // civil days — the repository owns the cross-midnight lookup.
                final progress = PrayerRepository.instance.progressAt(
                  view.settings,
                  _now,
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _LocationLine(
                      label: view.cityLabel,
                      isUnset: view.cityLabel.isEmpty,
                      onTap: () => _openSettings(context),
                    ),
                    const SizedBox(height: 6),
                    // Next-prayer hero: name + countdown in one line.
                    // No clock icon: the countdown digits already say that.
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        Text(
                          prayerEventName(context, next.id),
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 2,
                          ),
                          child: Text(
                            _formatDuration(left),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.primary,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                    if (progress != null) ...[
                      const SizedBox(height: 8),
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 260),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final width = constraints.maxWidth;
                              // The surface is laid out at width 0 for its first frame(s); nothing
                              // sensible to draw yet, and the clamp below would throw.
                              if (!width.isFinite || width < 18)
                                return const SizedBox.shrink();

                              final marker = _markerFor(next.id);
                              final dx = width * progress;
                              final isRtl = Directionality.of(context) ==
                                  TextDirection.rtl;
                              final tip = (dx - 9)
                                  .clamp(0.0, math.max(0.0, width - 18))
                                  .toDouble();
                              return Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(99),
                                      child: LinearProgressIndicator(
                                        value: progress,
                                        minHeight: 4,
                                        backgroundColor: colorScheme.primary
                                            .withValues(alpha: 0.15),
                                      ),
                                    ),
                                  ),
                                  // Opaque next-prayer icon riding the
                                  // fill tip.
                                  Positioned(
                                    left: isRtl ? null : tip,
                                    right: isRtl ? tip : null,
                                    top: -2,
                                    child: Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: marker.color,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        marker.icon,
                                        size: 10,
                                        color: Colors.white,
                                        semanticLabel: prayerEventName(
                                          context,
                                          next.id,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
    );
  }

  void _openSettings(BuildContext context) {
    // TODO: route to settings
    // showDialog<void>(
    //   context: context,
    //   builder: (_) => const PrayerSettingsDialog(),
    // );
  }

  /// Opaque marker for the bar's fill tip: the next prayer's timetable
  /// icon in its timetable tint, mirroring [PrayerTimingsCard].
  ({IconData icon, Color color}) _markerFor(PrayerEventId id) =>
      prayerIconFor(id);

  String _formatDuration(Duration duration) {
    if (duration.isNegative) {
      return '00:00:00';
    }
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
  }
}

class _UnsetContent extends StatelessWidget {
  const _UnsetContent({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _LocationLine(label: '', isUnset: true, onTap: onTap),
        const SizedBox(height: 4),
        Text(
          "انقر لتحديد موقك",
          style: const TextStyle(fontSize: 14),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Tappable location line shown above the countdown.
/// Unset state invites the user to pick a location.
class _LocationLine extends StatelessWidget {
  const _LocationLine({
    required this.label,
    required this.isUnset,
    required this.onTap,
  });
  final String label;
  final bool isUnset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isUnset
                  ? Icons.location_off_outlined
                  : Icons.location_on_outlined,
              size: 14,
              color: isUnset ? theme.hintColor : theme.colorScheme.primary,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                isUnset ? "موقع غير محدد" : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isUnset
                      ? theme.hintColor
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
