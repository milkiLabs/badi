import 'dart:async';
import 'dart:convert';
import 'package:badi/prayers/city.dart';
import 'package:badi/prayers/schedule.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Centralized SharedPreferences keys. The native prayer-notification config
/// reads the same values, so `prayer_notification_service.dart` must use
/// these constants instead of duplicating literals.
abstract final class PrefsKeys {
  static const String latitude = 'latitude';
  static const String longitude = 'longitude';
  static const String cityInfo = 'cityInfo';
  static const String cityLabel = 'cityLabel';
  static const String method = 'method';
  static const String asrCalculation = 'asrCalculation';
  static const String highLatitudeRule = 'highLatitudeRule';
  static const String timezone = 'timezone';
  static const String hijriDayOffset = 'hijri_day_offset';
}

void logWarn(Object message) {
  if (kDebugMode) debugPrint('[WARN] $message');
}

/// Fire-and-forget write with a visible warning on failure instead of a
/// silent drop. Reads/writes through the shared_preferences mock update the
/// in-memory cache synchronously, so an immediate `get` after a `set` still
/// observes the value (existing tests rely on this).
void _persist(Future<bool> write, String what) {
  unawaited(
    write.then((ok) {
      if (!ok) logWarn('Failed to persist $what');
    }).catchError((Object e) {
      logWarn('Failed to persist $what: $e');
    }),
  );
}

// ---------------------------------------------------------------------------
// Focused stores. Each owns one unrelated preference domain and takes a
// non-nullable [SharedPreferences], so domains can be used (and tested)
// without touching the app-wide facade below.
// ---------------------------------------------------------------------------

/// Prayer/location/calculation settings.
class PrayerPrefs {
  PrayerPrefs(this._prefs);

  final SharedPreferences _prefs;

  double getLatitude() => _prefs.getDouble(PrefsKeys.latitude) ?? 0.0;

  double getLongitude() => _prefs.getDouble(PrefsKeys.longitude) ?? 0.0;

  /// The city chosen in the city picker, if any (GPS selections clear it).
  /// Coordinates themselves stay in the latitude/longitude keys.
  void setCity(City? city) {
    if (city == null) {
      _persist(_prefs.remove(PrefsKeys.cityInfo), 'city');
      return;
    }
  }

  City? getCity() {
    final raw = _prefs.getString(PrefsKeys.cityInfo);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final lat = getLatitude();
      final lng = getLongitude();
      if (lat == 0.0 && lng == 0.0) return null;
      return City(
        nameEn: json['en'] as String,
        nameAr: json['ar'] as String?,
        countryCode: json['country'] as String,
        latitude: lat,
        longitude: lng,
      );
    } catch (e) {
      logWarn('Failed to parse stored city info: $e — dropping corrupt key');
      _persist(_prefs.remove(PrefsKeys.cityInfo), 'corrupt city info');
      return null;
    }
  }

  /// Display label for the configured location ('القاهرة، مصر'), computed
  /// once at save time (city pick → its label; GPS → nearest city within
  /// 50 km, else coordinates) and stored as a plain string so rendering
  /// never needs the city directory. Empty when no location is configured.
  String getPrayerCityLabel() => _prefs.getString(PrefsKeys.cityLabel) ?? '';

  /// Stored method or default. Absent returns the default; present-but-unknown
  /// values are logged visibly and reset to default (no silent guess).
  String getMethod() => _getValidatedString(
        PrefsKeys.method,
        PrayerMethods.isValid,
        PrayerMethods.egyptian,
        'prayer method',
      );

  String getAsrCalculation() => _getValidatedString(
        PrefsKeys.asrCalculation,
        PrayerMadhabs.isValid,
        PrayerMadhabs.shafi,
        'madhab',
      );

  String getHighLatitudeRule() => _getValidatedString(
        PrefsKeys.highLatitudeRule,
        PrayerHighLatitudeRules.isValid,
        PrayerHighLatitudeRules.middleOfNight,
        'high-latitude rule',
      );

  /// Generic validated-string reader: absent → default, unknown → log + default.
  String _getValidatedString(
    String key,
    bool Function(String) isValid,
    String fallback,
    String what,
  ) {
    final stored = _prefs.getString(key);
    if (stored == null) return fallback;
    if (!isValid(stored)) {
      logWarn('Unknown stored $what "$stored" — using default');
      return fallback;
    }
    return stored;
  }

  int getHijriDayOffset() => _prefs.getInt(PrefsKeys.hijriDayOffset) ?? 0;

  void setHijriDayOffset(int offset) =>
      _persist(_prefs.setInt(PrefsKeys.hijriDayOffset, offset), 'hijri offset');

  String getTimezone() => _prefs.getString(PrefsKeys.timezone) ?? '';

  /// Typed snapshot of all prayer settings. Single source of defaults and
  /// validation for the UI, the calculator, and the native bridge.
  PrayerSettings loadPrayerSettings() {
    return PrayerSettings(
      latitude: getLatitude(),
      longitude: getLongitude(),
      timezone: getTimezone(),
      method: getMethod(),
      madhab: getAsrCalculation(),
      highLatitudeRule: getHighLatitudeRule(),
    );
  }

  /// Saves interdependent prayer settings together, then refreshes the native
  /// notification once so it cannot observe a half-saved location or zone.
  Future<void> savePrayerSettings({
    required double latitude,
    required double longitude,
    required String method,
    required String asrCalculation,
    required String timezone,
    String? highLatitudeRule,
    City? city,
    String? cityLabel, // null = leave stored label unchanged
  }) async {
    await Future.wait([
      _prefs.setDouble(PrefsKeys.latitude, latitude),
      _prefs.setDouble(PrefsKeys.longitude, longitude),
      _prefs.setString(PrefsKeys.method, method),
      _prefs.setString(PrefsKeys.asrCalculation, asrCalculation),
      _prefs.setString(PrefsKeys.timezone, timezone),
      if (highLatitudeRule != null)
        _prefs.setString(PrefsKeys.highLatitudeRule, highLatitudeRule),
      if (city == null)
        _prefs.remove(PrefsKeys.cityInfo)
      else
        _prefs.setString(
          PrefsKeys.cityInfo,
          jsonEncode({
            'en': city.nameEn,
            'ar': city.nameAr,
            'country': city.countryCode,
          }),
        ),
      if (cityLabel != null) _prefs.setString(PrefsKeys.cityLabel, cityLabel),
    ]);
    // await refreshPrayerNotification();
  }
}

// ---------------------------------------------------------------------------
// App-wide facade. Kept for the existing call sites (see blast-radius note);
// new code should prefer `SharedPreferencesService.instance.<domain>`.
// Every accessor goes through [_prefs], which throws a [StateError] before
// init instead of silently returning defaults or dropping writes.
// ---------------------------------------------------------------------------

class SharedPreferencesService {
  /// Historical throwaway-constructible entry point (`().init()` in main and
  /// existing tests). The constructed object holds no state; [init] populates
  /// the static holder. New code should call [ensureInitialized] directly.
  SharedPreferencesService();

  /// Preferred entry point for new code: `await SharedPreferencesService.init()`
  /// once in `main()` before `runApp`, then `SharedPreferencesService.instance`
  /// (or the static shims below during migration).
  SharedPreferencesService._(SharedPreferences prefs)
      : prayer = PrayerPrefs(prefs);

  late final PrayerPrefs prayer;

  static SharedPreferencesService? _instance;

  /// True once [init]/[ensureInitialized] has completed.
  static bool get isInitialized => _instance != null;

  /// Fail-fast accessor: throws [StateError] when used before init.
  static SharedPreferencesService get instance {
    final current = _instance;
    if (current == null) {
      throw StateError(
        'SharedPreferencesService.init() must be awaited before use '
        '(call it in main() before runApp).',
      );
    }
    return current;
  }

  /// Idempotent async initializer. Safe to call more than once.
  static Future<void> ensureInitialized() async {
    if (_instance != null) return;
    final prefs = await SharedPreferences.getInstance();
    _instance = SharedPreferencesService._(prefs);
  }

  /// Historical entry point (`SharedPreferencesService().init()` in main and
  /// tests). Always re-reads the backing store so tests that reset the mock
  /// (`setMockInitialValues` + `init()`) observe fresh values; new code
  /// should call [ensureInitialized] directly.
  Future<void> init() async {
    resetForTest();
    await ensureInitialized();
  }

  @visibleForTesting
  static void resetForTest() {
    _instance = null;
  }
}
