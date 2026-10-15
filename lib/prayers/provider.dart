import 'dart:async';
import 'package:badi/prayers/city_directory.dart';
import 'package:badi/prayers/repository.dart';
import 'package:badi/prayers/schedule.dart';
import 'package:badi/prayers/city.dart';
import 'package:badi/prayers/shared_pref.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

/// Thin Riverpod glue over [PrayerRepository]. Holds no prayer data itself:
/// one stored config plus derived values. See `prayer_repository.dart` for
/// why nothing cached can go stale.
///
/// Battery profile: one 1-second timer while the countdown is mounted, one
/// one-shot boundary timer app-wide (~7 wakeups/day), zero Dart wakeups
/// otherwise.

/// Stored prayer configuration: calculation inputs plus the display label
/// saved alongside them ('القاهرة، مصر'). Single writer:
/// [savePrayerSettings] publishes through [PrayerConfigNotifier.publish].
/// [relabelCityForLocale] re-derives the label on language switches.
class PrayerConfig {
  const PrayerConfig({required this.settings, required this.cityLabel});
  final PrayerSettings settings;
  final String cityLabel;
}

class PrayerConfigNotifier extends Notifier<PrayerConfig> {
  @override
  PrayerConfig build() => PrayerConfig(
        settings: SharedPreferencesService.instance.prayer.loadPrayerSettings(),
        cityLabel:
            SharedPreferencesService.instance.prayer.getPrayerCityLabel(),
      );

  void publish(PrayerSettings settings, String cityLabel) =>
      state = PrayerConfig(settings: settings, cityLabel: cityLabel);
}

final prayerConfigProvider =
    NotifierProvider<PrayerConfigNotifier, PrayerConfig>(
  PrayerConfigNotifier.new,
);

/// Rebuild nudge. Bumped at event boundaries (one-shot timer) and whenever
/// the ticking countdown observes a new next prayer (covers manual clock
/// jumps within a second). Cosmetic consumers (highlight, weekday, dates)
/// rebuild on this; correctness never depends on it — the countdown always
/// derives live values from wall-clock time.
final prayerNudgeProvider =
    NotifierProvider<PrayerNudgeNotifier, int>(PrayerNudgeNotifier.new);

/// Everything the prayer UI needs, derived fresh on each nudge or config
/// change. Null when unconfigured (setup prompt takes over — there is no
/// separate loading state; prefs and the tz database are ready before
/// `runApp`, so a null view unambiguously means "no saved location").
class PrayerView {
  const PrayerView({
    required this.settings,
    required this.schedule,
    required this.next,
    required this.weekday,
    required this.today,
    required this.cityLabel,
  });
  final PrayerSettings settings;
  final PrayerSchedule schedule;
  final PrayerEvent next;
  final int weekday;
  final tz.TZDateTime today;
  final String cityLabel;
}

final prayerViewProvider = Provider<PrayerView?>((ref) {
  ref.watch(prayerNudgeProvider);
  final config = ref.watch(prayerConfigProvider);
  final settings = config.settings;
  final snap = PrayerRepository.instance.snapshot(
    settings,
    DateTime.now(),
  );
  if (snap == null) return null;
  return PrayerView(
    settings: settings,
    schedule: snap.schedule,
    next: snap.next,
    weekday: snap.weekday,
    today: snap.zoned,
    cityLabel: config.cityLabel,
  );
});

/// Owns the single one-shot boundary timer. On fire it bumps the version so
/// derived providers re-evaluate; [poke] does the same when the countdown
/// observes a next-prayer change, and also re-arms (a clock jump invalidates
/// the previously armed instant). Re-arms on every config change. Never
/// stores prayer data, so a misfire is at worst a cosmetic delay.
///
/// Note the dependency direction: the view watches this nudge, while this
/// notifier watches only the config. The reverse — listening to the view
/// here — would be a dependency cycle.
class PrayerNudgeNotifier extends Notifier<int> {
  Timer? _timer;

  @override
  int build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(prayerConfigProvider, (_, __) => _rearm());
    _rearm();
    return 0;
  }

  void poke() {
    state++;
    _rearm();
  }

  void _rearm() {
    _timer?.cancel();
    final settings = ref.read(prayerConfigProvider).settings;
    final location = settings.locationOrNull;
    if (location == null) return;
    final now = tz.TZDateTime.now(location);
    final target = PrayerRepository.instance.nextBoundaryAt(settings, now);
    if (target == null) return;
    final delay = target.difference(now);
    if (delay.isNegative) return;
    _timer = Timer(delay, () {
      if (!ref.mounted) return;
      state++;
      _rearm();
    });
  }
}

/// Validates, persists, and publishes interdependent prayer settings as one
/// atomic unit: one prefs write + one native-table push + one provider
/// publish, so no reader can observe a half-saved location/timezone/method.
/// Returns false when the timezone can't be resolved (nothing saved).
///
/// Display label only: GPS (city == null) → nearest city within 50 km, else
/// coordinates. Prayer math keeps using the exact coordinates.
///
/// Takes the loaded [directory] and a [publish] callback instead of a ref,
/// so widget callers pass `ref.read` pieces and tests pass a container's
/// notifier without pumping a widget.
Future<bool> savePrayerSettings({
  required CityDirectory directory,
  required void Function(PrayerSettings settings, String cityLabel) publish,
  required double lat,
  required double long,
  required String method,
  required String asrCalc,
  String? highLatitudeRule,
  City? city,
  String languageCode = 'ar',
}) async {
  // Single directory scan for both timezone and display label (see
  // [CityDirectory.resolveSelection]).
  final resolved = directory.resolveSelection(
    lat: lat,
    lng: long,
    selectedCity: city,
    languageCode: languageCode,
  );
  final timezone = resolved.timezone;
  if (timezone == null || timezone.isEmpty) return false;
  final cityLabel = resolved.label;
  if (cityLabel.isEmpty) return false;

  await SharedPreferencesService.instance.prayer.savePrayerSettings(
    latitude: lat,
    longitude: long,
    method: method,
    asrCalculation: asrCalc,
    timezone: timezone,
    highLatitudeRule: highLatitudeRule,
    city: city,
    cityLabel: cityLabel,
  );
  publish(
    PrayerSettings(
      latitude: lat,
      longitude: long,
      timezone: timezone,
      method: method,
      madhab: asrCalc,
      highLatitudeRule:
          highLatitudeRule ?? PrayerHighLatitudeRules.middleOfNight,
    ),
    cityLabel,
  );
  return true;
}

/// Re-derives the stored city label in [languageCode] after a UI-locale
/// change, without touching coordinates, method, or madhab. No-op when no
/// location is configured or the label can't be resolved.
///
/// Unlike [savePrayerSettings] this never asks for exact-alarm access: it is
/// a label-only refresh, not a first setup. The service save re-pushes the
/// native table, so the notification follows the new language too.
///
/// Takes the loaded [directory] and a [publish] callback like
/// [savePrayerSettings] so tests pass an in-memory instance.
Future<void> relabelCityForLocale({
  required CityDirectory directory,
  required void Function(PrayerSettings settings, String cityLabel) publish,
  required String languageCode,
}) async {
  final lat = SharedPreferencesService.instance.prayer.getLatitude();
  final lng = SharedPreferencesService.instance.prayer.getLongitude();
  if (lat == 0.0 && lng == 0.0) return;
  final city = SharedPreferencesService.instance.prayer.getCity();
  final resolved = directory.resolveSelection(
    lat: lat,
    lng: lng,
    selectedCity: city,
    languageCode: languageCode,
  );
  if (resolved.timezone == null ||
      resolved.timezone!.isEmpty ||
      resolved.label.isEmpty) {
    return;
  }
  await SharedPreferencesService.instance.prayer.savePrayerSettings(
    latitude: lat,
    longitude: lng,
    method: SharedPreferencesService.instance.prayer.getMethod(),
    asrCalculation:
        SharedPreferencesService.instance.prayer.getAsrCalculation(),
    timezone: resolved.timezone!,
    highLatitudeRule:
        SharedPreferencesService.instance.prayer.getHighLatitudeRule(),
    city: city,
    cityLabel: resolved.label,
  );
  publish(
    PrayerSettings(
      latitude: lat,
      longitude: lng,
      timezone: resolved.timezone!,
      method: SharedPreferencesService.instance.prayer.getMethod(),
      madhab: SharedPreferencesService.instance.prayer.getAsrCalculation(),
      highLatitudeRule:
          SharedPreferencesService.instance.prayer.getHighLatitudeRule(),
    ),
    resolved.label,
  );
}

class HijriOffsetNotifier extends Notifier<int> {
  @override
  int build() =>
      SharedPreferencesService.instance.prayer.getHijriDayOffset();

  void set(int offset) {
    SharedPreferencesService.instance.prayer.setHijriDayOffset(offset);
    state = offset;
  }
}

final hijriOffsetProvider =
    NotifierProvider<HijriOffsetNotifier, int>(HijriOffsetNotifier.new);
