// country_defaults.dart
//
// Suggests prayer calculation method + Asr madhab from an ISO country code.
// Suggest-only: the user can always override both in the UI.
//
// Sources for the method mapping (region-used tables, not fatwas):
// - praytimes.org/docs/methods (Karachi = PK/AF/BD/IN, Egypt = Africa/Syria/
//   Lebanon, Makkah = Arabian Peninsula, ISNA = US/CA, MWL = Europe/Far East)
// - aladhan.com/calculation-methods + api.aladhan.com/v1/methods (adds
//   Gulf/Kuwait/Qatar/Dubai/Turkey-Diyanet/Algeria/Tunisia/Morocco/
//   Indonesia-Kemenag/Singapore/France/Russia/Portugal angles).
//
// Sources for the madhab mapping (Asr only distinguishes Hanafi=late vs
// Standard/Shafi-Maliki-Hanbali=early):
// - Pew "Mapping the Global Muslim Population"
// - Madhab-by-country maps (LookLex / encyclopedias): Hanafi = South Asia +
//   Turkey/Central Asia/Balkans + Levant; Maliki = North Africa;
//   Shafi'i = SE Asia/Yemen/Horn; Hanbali = SA/QA/AE.
// Unknown codes fall back to (muslimWorldLeague, shafi); US/CA fall back to
// northAmerica (ISNA-equivalent in this codebase).

import 'package:badi/prayers/schedule.dart';

/// Calculation-method override per ISO 3166-1 alpha-2 country code.
/// Absent codes use [_fallbackMethodFor].
const Map<String, String> _methodByCountry = {
  // Arabian Peninsula (Makkah = peninsula per PrayTimes).
  'SA': PrayerMethods.ummAlQura,
  'YE': PrayerMethods.ummAlQura,
  'AE': PrayerMethods.dubai,
  'QA': PrayerMethods.qatar,
  'KW': PrayerMethods.kuwait,
  'BH': PrayerMethods.gulfRegion,
  'OM': PrayerMethods.gulfRegion,
  // South Asia (Karachi per PrayTimes).
  'PK': PrayerMethods.karachi,
  'IN': PrayerMethods.karachi,
  'BD': PrayerMethods.karachi,
  'AF': PrayerMethods.karachi,
  'NP': PrayerMethods.karachi,
  'LK': PrayerMethods.karachi,
  'BT': PrayerMethods.karachi,
  // Turkey + Turkic/Central Asia + Balkans (Diyanet, Hanafi).
  'TR': PrayerMethods.turkey,
  'AZ': PrayerMethods.turkey,
  'KZ': PrayerMethods.turkey,
  'UZ': PrayerMethods.turkey,
  'KG': PrayerMethods.turkey,
  'TJ': PrayerMethods.turkey,
  'TM': PrayerMethods.turkey,
  'BA': PrayerMethods.turkey,
  'AL': PrayerMethods.turkey,
  'XK': PrayerMethods.turkey,
  'MK': PrayerMethods.turkey,
  // Egypt / Levant / North-East Africa (Egyptian per PrayTimes).
  'EG': PrayerMethods.egyptian,
  'SD': PrayerMethods.egyptian,
  'LY': PrayerMethods.egyptian,
  'SY': PrayerMethods.egyptian,
  'LB': PrayerMethods.egyptian,
  'IQ': PrayerMethods.egyptian,
  // North-Africa specifics.
  'DZ': PrayerMethods.algerian,
  'MA': PrayerMethods.morocco,
  'TN': PrayerMethods.tunisia,
  'JO': PrayerMethods.jordan,
  'PS': PrayerMethods.jordan,
  // SE Asia (20/18 group, Shafi).
  'ID': PrayerMethods.indonesian,
  'MY': PrayerMethods.singapore,
  'SG': PrayerMethods.singapore,
  'BN': PrayerMethods.singapore,
  // Iran + country-specific Europeans.
  'IR': PrayerMethods.tehran,
  'FR': PrayerMethods.france,
  'RU': PrayerMethods.russia,
  'PT': PrayerMethods.portugal,
  // North America (ISNA-equivalent).
  'US': PrayerMethods.northAmerica,
  'CA': PrayerMethods.northAmerica,
};

/// Hanafi-majority codes (late Asr). Every other code suggests shafi
/// (= Standard timing shared by Shafi/Maliki/Hanbali).
/// EG left as shafi: mixed Hanafi/Shafi, Standard is the common app default.
const Set<String> _hanafiCountries = {
  'PK',
  'IN',
  'BD',
  'AF',
  'NP',
  'LK',
  'BT',
  'TR',
  'AZ',
  'KZ',
  'UZ',
  'KG',
  'TJ',
  'TM',
  'BA',
  'AL',
  'XK',
  'MK',
  'SY',
  'JO',
  'LB',
  'PS',
  'RU',
};

String _fallbackMethodFor(String code) {
  if (code == 'US' || code == 'CA') return PrayerMethods.northAmerica;
  return PrayerMethods.muslimWorldLeague;
}

/// Suggests `(method, madhab)` for [countryCode] (case-insensitive).
/// Never throws: unknown/empty codes yield the fallback.
({String method, String madhab}) suggestPrayerDefaultsForCountry(
  String countryCode,
) {
  final code = countryCode.trim().toUpperCase();
  final method = _methodByCountry[code] ?? _fallbackMethodFor(code);
  final madhab = _hanafiCountries.contains(code)
      ? PrayerMadhabs.hanafi
      : PrayerMadhabs.shafi;
  return (method: method, madhab: madhab);
}
