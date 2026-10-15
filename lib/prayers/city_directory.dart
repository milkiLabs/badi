// city_directory.dart
//
// Offline, in-memory directory of ~34k world cities used by the prayer
// timings city picker.
//
// Loading: the JSON asset (~2.3 MB raw) is parsed on demand when the city
// picker opens, shown behind its loading spinner, and discarded when the
// sheet closes. Search is a single linear scan: entries are rejected
// with one cheap substring check each, and exact/prefix/word-start tiering
// runs only on the few entries that contain the query. The UI additionally
// debounces keystrokes.

import 'dart:convert';
import 'dart:isolate';

import 'package:badi/prayers/city.dart';
import 'package:badi/prayers/location_timezone.dart';
import 'package:flutter/services.dart';

final RegExp _arabicDiacritics =
    RegExp(r'[\u064B-\u0652\u0670\u0640\u200C\u200D]');
final RegExp _arabicHamzaVariants = RegExp('[أإآٱ]');
final RegExp _arabicWhitespace = RegExp(r'\s+');
String normalizeArabic(String input) {
  final out = input
      .replaceAll(_arabicDiacritics, '')
      .replaceAll(_arabicHamzaVariants, 'ا')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ي')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .toLowerCase();
  return out.replaceAll(_arabicWhitespace, ' ').trim();
}

/// Precomputed normalized search forms for one city.
class _IndexedCity {
  _IndexedCity(this.city, this.order, CountryInfo? country)
      : normAr = normalizeArabic(city.nameAr ?? ''),
        normEn = normalizeArabic(city.nameEn),
        normCountryAr = normalizeArabic(country?.nameAr ?? ''),
        normCountryEn = normalizeArabic(country?.nameEn ?? '');
  final City city;

  /// Population rank proxy: lower index == larger city (asset is sorted by
  /// population descending). Used as a tiebreaker so well-known cities
  /// surface first.
  final int order;
  final String normAr;
  final String normEn;
  final String normCountryAr;
  final String normCountryEn;
}

class CityDirectory {
  CityDirectory({required this.cities, required this.countries})
      : _index = [
          for (var i = 0; i < cities.length; i++)
            _IndexedCity(cities[i], i, countries[cities[i].countryCode]),
        ];

  factory CityDirectory.fromJson(Map<String, dynamic> json) {
    final countriesJson = json['countries'] as Map<String, dynamic>;
    return CityDirectory(
      cities: [
        for (final c in json['cities'] as List)
          City.fromJson(c as Map<String, dynamic>),
      ],
      countries: {
        for (final e in countriesJson.entries)
          e.key: CountryInfo.fromJson(e.key, e.value as Map<String, dynamic>),
      },
    );
  }
  final List<City> cities;
  final Map<String, CountryInfo> countries;

  /// Search index, built eagerly in the constructor so the sheet's
  /// loading spinner covers both JSON parsing and indexing.
  final List<_IndexedCity> _index;

  /// Loads and parses the bundled asset. No caching: each call returns a
  /// fresh instance; callers load on demand and drop it when done.
  /// run on a background isolate not to block the UI thread
  static Future<CityDirectory> load() async {
    final raw = await rootBundle.loadString('assets/data/cities.json');
    // NOTE: uncomment if we ever publish to web.
    // if (kIsWeb) {
    //   return CityDirectory.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    // }
    return await Isolate.run(
      () => CityDirectory.fromJson(jsonDecode(raw) as Map<String, dynamic>),
    );
  }

  /// Country name for the Arabic UI (Arabic, English fallback, code last).
  String countryLabel(String code) {
    final info = countries[code];
    if (info == null) return code;
    return info.displayName;
  }

  /// Locale-aware country name. Unknown codes return the code itself.
  String countryLabelFor(String code, String languageCode) {
    final info = countries[code];
    if (info == null) return code;
    return info.displayNameFor(languageCode);
  }

  /// 'City، Country' label, e.g. 'القاهرة، مصر'.
  String cityLabel(City city) =>
      '${city.displayName}، ${countryLabel(city.countryCode)}';

  /// Locale-aware 'City, Country' label ('Cairo, Egypt' in English).
  /// Labels are localized once at creation (pick/resolve) and stored
  /// verbatim, so this never reinterprets a stored string.
  String cityLabelFor(City city, String languageCode) {
    final separator = languageCode == 'en' ? ', ' : '، ';
    return '${city.displayNameFor(languageCode)}$separator'
        '${countryLabelFor(city.countryCode, languageCode)}';
  }

  /// Single source for timezone + display label: one directory scan.
  /// [selectedCity] (city pick) uses its own timezone and label directly;
  /// GPS (`selectedCity: null`) uses the nearest timezone and the nearest
  /// city within 50 km for the label, else coordinates. Prayer math always
  /// keeps the exact [lat]/[lng].
  ///
  /// [languageCode] localizes the returned label once ('ar' default keeps
  /// the native payload and existing callers on Arabic). The label is
  /// stored verbatim — never re-localized on read.
  ({String? timezone, String label, City? labelCity}) resolveSelection({
    required double lat,
    required double lng,
    City? selectedCity,
    String languageCode = 'ar',
  }) {
    if (selectedCity != null) {
      final tz = selectedCity.timeZone;
      if (tz != null && tz.isNotEmpty) {
        return (
          timezone: tz,
          label: cityLabelFor(selectedCity, languageCode),
          labelCity: selectedCity
        );
      }
    }
    final resolved = LocationTimezone.resolveBoth(
      latitude: lat,
      longitude: lng,
      cities: cities,
      selectedCity: selectedCity,
    );
    final timezone = resolved.timezone;
    if (timezone == null) return (timezone: null, label: '', labelCity: null);
    final city = selectedCity ?? resolved.nearestCity;
    if (city == null) {
      final separator = languageCode == 'en' ? ', ' : '، ';
      return (
        timezone: timezone,
        label: '${lat.toStringAsFixed(2)}°$separator${lng.toStringAsFixed(2)}°',
        labelCity: null,
      );
    }
    return (
      timezone: timezone,
      label: cityLabelFor(city, languageCode),
      labelCity: city
    );
  }

  /// Searches Arabic and English city AND country names. Tiers (best first):
  /// city exact (100) > country exact (90) > city prefix (80) >
  /// country prefix (70) > city word-start (60) > country word-start (50) >
  /// city substring (40) > country substring (30),
  /// with a small population bonus inside each tier. Typing a country name
  /// (e.g. 'مصر' or 'Egypt') therefore lists that country's cities.
  /// Returns at most [limit] matches, best first. Empty/blank query returns [].
  List<City> search(String query, {int limit = 60}) {
    final q = normalizeArabic(query);
    if (q.isEmpty) return const [];
    final scored = _scoreAll(q)..sort((a, b) => b.score.compareTo(a.score));
    final count = scored.length < limit ? scored.length : limit;
    return [for (var i = 0; i < count; i++) scored[i].city];
  }

  /// Scores every entry matching [q] (already normalized, non-empty),
  /// in index order (unsorted). Single scan shared via [search].

  /// Scores every entry matching [q] (already normalized, non-empty),
  /// in index order (unsorted).
  List<({City city, int score})> _scoreAll(String q) {
    final total = _index.length;
    final scored = <({City city, int score})>[];
    for (final entry in _index) {
      // Cheap reject first: one substring scan per name, no allocations.
      // Exact/prefix/word-start tiering runs only for entries containing
      // the query — a tiny fraction of the directory for normal queries.
      final cityHit = entry.normAr.contains(q) || entry.normEn.contains(q);
      final countryHit =
          entry.normCountryAr.contains(q) || entry.normCountryEn.contains(q);
      if (!cityHit && !countryHit) continue;
      final cityTier = cityHit ? _matchTier(entry.normAr, entry.normEn, q) : 0;
      final countryTier = countryHit
          ? _matchTier(entry.normCountryAr, entry.normCountryEn, q)
          : 0;
      // Country hits rank one step below the equivalent city hit so a
      // city-name match always outranks a country-name match.
      var tier = cityTier;
      final countryScore = countryTier > 0 ? countryTier - 10 : 0;
      if (countryScore > tier) tier = countryScore;
      // Unreachable: a contains-hit always tiers >= 40. Kept as a guard.
      if (tier == 0) continue;
      // 0..9 bonus: earlier (more populous) cities rank higher in-tier.
      final popularity = ((total - entry.order) / total * 9).round();
      scored.add((city: entry.city, score: tier + popularity));
    }
    return scored;
  }

  /// Tier for a (arabic, english) name pair: exact 100 > prefix 80 >
  /// word-start 60 > substring 40, else 0.
  static int _matchTier(String normAr, String normEn, String q) {
    if (q.isEmpty) return 0;
    if ((normAr.isNotEmpty && normAr == q) || normEn == q) return 100;
    if ((normAr.isNotEmpty && normAr.startsWith(q)) || normEn.startsWith(q)) {
      return 80;
    }
    if ((normAr.isNotEmpty && _wordStarts(normAr, q)) ||
        _wordStarts(normEn, q)) {
      return 60;
    }
    if ((normAr.isNotEmpty && normAr.contains(q)) || normEn.contains(q)) {
      return 40;
    }
    return 0;
  }

  /// True when [q] matches the start of any whitespace-separated word.
  /// Allocation-free: scans [text] with `indexOf` instead of building
  /// padded copies (`(' $text ').contains(' $q')`) per entry per keystroke.
  static bool _wordStarts(String text, String q) {
    if (q.length > text.length) return false;
    if (text.startsWith(q)) return true;
    var i = text.indexOf(q, 1);
    while (i != -1) {
      if (text.codeUnitAt(i - 1) == 0x20) return true;
      i = text.indexOf(q, i + 1);
    }
    return false;
  }
}
