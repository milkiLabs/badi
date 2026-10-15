import 'package:badi/prayers/schedule.dart';

class CalculationMethodInfo {
  const CalculationMethodInfo({
    required this.key,
    required this.arabicName,
    required this.englishName,
  });
  final String
      key; // These keys MUST match adhan_dart's CalculationMethod names
  final String arabicName;
  final String englishName;

  static const List<CalculationMethodInfo> methods = [
    // Keys MUST match [PrayerMethods] (the cross-platform contract).
    CalculationMethodInfo(
      key: PrayerMethods.muslimWorldLeague,
      arabicName: 'رابطة العالم الإسلامي',
      englishName: 'Muslim World League',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.egyptian,
      arabicName: 'الهيئة المصرية العامة للمساحة',
      englishName: 'Egyptian General Authority of Survey',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.karachi,
      arabicName: 'جامعة العلوم الإسلامية، كراتشي',
      englishName: 'University of Islamic Sciences, Karachi',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.ummAlQura,
      arabicName: 'جامعة أم القرى، مكة المكرمة',
      englishName: 'Umm al-Qura University, Makkah',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.dubai,
      arabicName: 'هيئة دبي للأوقاف والشؤون الإسلامية',
      englishName: 'Dubai Endowments and Islamic Affairs',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.qatar,
      arabicName: 'وزارة الأوقاف والشؤون الإسلامية القطرية',
      englishName: 'Qatari Ministry of Awqaf and Islamic Affairs',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.kuwait,
      arabicName: 'وزارة الأوقاف والشؤون الإسلامية الكويتية',
      englishName: 'Kuwaiti Ministry of Awqaf and Islamic Affairs',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.moonSightingCommittee,
      arabicName: 'لجنة رؤية الهلال',
      englishName: 'Moonsighting Committee',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.singapore,
      arabicName: 'المجلس الإسلامي في سنغافورة (MUIS)',
      englishName: 'Islamic Religious Council of Singapore (MUIS)',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.turkey,
      arabicName: 'رئاسة الشؤون الدينية التركية (ديانت)',
      englishName: 'Turkish Presidency of Religious Affairs (Diyanet)',
    ), // Note: 'turkiye'
    CalculationMethodInfo(
      key: PrayerMethods.tehran,
      arabicName: 'معهد الجيوفيزياء بجامعة طهران',
      englishName: 'Geophysics Institute, University of Tehran',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.northAmerica,
      arabicName: 'الجمعية الإسلامية لأمريكا الشمالية (ISNA)',
      englishName: 'Islamic Society of North America (ISNA)',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.algerian,
      arabicName: 'وزارة الشؤون الدينية والأوقاف الجزائرية',
      englishName: 'Algerian Ministry of Religious Affairs and Endowments',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.jordan,
      arabicName: 'وزارة الأوقاف والشؤون والمقدسات الإسلامية الأردنية',
      englishName: 'Jordanian Ministry of Awqaf and Islamic Affairs',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.morocco,
      arabicName: 'وزارة الأوقاف والشؤون الإسلامية المغربية',
      englishName: 'Moroccan Ministry of Endowments and Islamic Affairs',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.tunisia,
      arabicName: 'وزارة الشؤون الدينية التونسية',
      englishName: 'Tunisian Ministry of Religious Affairs',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.gulfRegion,
      arabicName: 'تقويم منطقة الخليج',
      englishName: 'Gulf Region calendar',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.indonesian,
      arabicName: 'وزارة الشؤون الدينية الإندونيسية (KEMENAG)',
      englishName: 'Indonesian Ministry of Religious Affairs (KEMENAG)',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.france,
      arabicName: 'اتحاد المنظمات الإسلامية في فرنسا (UOIF)',
      englishName: 'Union of Islamic Organisations of France (UOIF)',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.portugal,
      arabicName: 'الجالية الإسلامية في لشبونة (البرتغال)',
      englishName: 'Islamic Community of Lisbon (Portugal)',
    ),
    CalculationMethodInfo(
      key: PrayerMethods.russia,
      arabicName: 'الإدارة الدينية لمسلمي روسيا',
      englishName: 'Religious Board of Muslims of Russia',
    ),
  ];

  static String getArabicName(String key) {
    try {
      return methods.firstWhere((method) => method.key == key).arabicName;
    } catch (e) {
      // Unknown key: visible fallback, never a silent wrong method.
      return key;
    }
  }

  /// Locale-aware method name: English UI shows [englishName], anything
  /// else shows [arabicName]. Unknown keys fall back to the raw key.
  static String getLocalizedName(String key, {String languageCode = 'ar'}) {
    try {
      final method = methods.firstWhere((method) => method.key == key);
      return languageCode == 'en' ? method.englishName : method.arabicName;
    } catch (e) {
      return key;
    }
  }
}
