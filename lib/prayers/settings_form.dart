import 'dart:async' show unawaited;

import 'package:badi/prayers/asr_calc_segmented_button.dart';
import 'package:badi/prayers/calc_method_drop_down.dart';
import 'package:badi/prayers/city.dart';
import 'package:badi/prayers/city_directory.dart';
import 'package:badi/prayers/city_picker.dart';
import 'package:badi/prayers/country_defaults.dart';
import 'package:badi/prayers/provider.dart';
import 'package:badi/prayers/schedule.dart';
import 'package:badi/prayers/shared_pref.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// Reusable prayer-settings editor (location + madhab + method).
///
/// Used inline by the settings page and wrapped in a `Dialog` by
/// `PrayerSettingsDialog`
class PrayerSettingsForm extends ConsumerStatefulWidget {
  const PrayerSettingsForm({super.key, this.showCancel = true, this.onSaved});

  /// When true (dialog use) a cancel button is shown next to save.
  final bool showCancel;
  final VoidCallback? onSaved;

  @override
  ConsumerState<PrayerSettingsForm> createState() => _PrayerSettingsFormState();
}

class _PrayerSettingsFormState extends ConsumerState<PrayerSettingsForm> {
  String _selectedAsrCalc = PrayerMadhabs.shafi;
  String _selectedMethod = PrayerMethods.egyptian;

  /// Location chosen via GPS (city null) or the city picker.
  double? _latitude;
  double? _longitude;
  City? _selectedCity;

  /// Same 'المدينة، الدولة' label as the prayer screen. City pick carries it
  /// from the sheet; GPS resolves it once via [CityDirectory.resolveSelection].
  String? _selectedCityLabel;

  /// Timezone matching [_selectedCityLabel]. City pick carries it from the
  /// sheet; GPS resolves it alongside the label, so save needs no reload.
  String? _selectedTimezone;

  /// Transient GPS-resolving flag. Replaces the old localized-sentinel
  /// label comparison so the in-flight state survives locale switches.
  bool _resolvingGpsLabel = false;

  /// Inline validation flag: shown as red text under the location section.
  bool _showLocationError = false;

  void _onCitySelected(({City city, String label}) picked) {
    final suggested = suggestPrayerDefaultsForCountry(picked.city.countryCode);
    setState(() {
      _selectedCity = picked.city;
      _selectedCityLabel = picked.label;
      _selectedTimezone = picked.city.timeZone;
      _latitude = picked.city.latitude;
      _longitude = picked.city.longitude;
      _resolvingGpsLabel = false;
      _showLocationError = false;
      // Auto-suggest: user can still override both after the pick.
      _selectedMethod = suggested.method;
      _selectedAsrCalc = suggested.madhab;
    });
  }

  void onGettingLocation({
    required String latitude,
    required String longitude,
  }) {
    final lat = double.tryParse(latitude);
    final lng = double.tryParse(longitude);
    if (lat == null || lng == null) return;
    setState(() {
      _latitude = lat;
      _longitude = lng;
      _selectedCity = null;
      _selectedCityLabel = null;
      _resolvingGpsLabel = true;
      _selectedTimezone = null;
      _showLocationError = false;
    });
    unawaited(_resolveGpsLabel(lat, lng));
  }

  Future<void> _resolveGpsLabel(double lat, double lng) async {
    // Capture before the await: the locale at request time owns the label.
    final languageCode = Localizations.localeOf(context).languageCode;
    try {
      final directory = await CityDirectory.load();
      if (!mounted) return;
      if (_selectedCity != null || _latitude != lat || _longitude != lng) {
        return;
      }
      final resolved = directory.resolveSelection(
        lat: lat,
        lng: lng,
        languageCode: languageCode,
      );
      if (!mounted) return;
      if (_selectedCity != null || _latitude != lat || _longitude != lng) {
        return;
      }
      setState(() {
        _selectedCityLabel = resolved.label;
        _selectedTimezone = resolved.timezone;
        _resolvingGpsLabel = false;
        final labelCity = resolved.labelCity;
        if (labelCity != null) {
          final suggested =
              suggestPrayerDefaultsForCountry(labelCity.countryCode);
          _selectedMethod = suggested.method;
          _selectedAsrCalc = suggested.madhab;
        }
      });
    } catch (_) {
      if (!mounted) return;
      if (_selectedCity != null || _latitude != lat || _longitude != lng) {
        return;
      }
      setState(() {
        _selectedCityLabel = null;
        _resolvingGpsLabel = false;
      });
    }
  }

  bool get _hasLocation => _latitude != null && _longitude != null;

  Future<void> _saveSettings() async {
    if (!_hasLocation) {
      if (mounted) setState(() => _showLocationError = true);
      return;
    }
    final languageCode = Localizations.localeOf(context).languageCode;

    // Stored label + timezone cover both paths (city sheet, GPS resolve).
    // One directory load only when missing (save-before-resolve, tz-less city).
    var timezone = _selectedCity?.timeZone;
    if (timezone == null || timezone.isEmpty) timezone = _selectedTimezone;
    var cityLabel = _selectedCityLabel;
    if (timezone == null ||
        timezone.isEmpty ||
        cityLabel == null ||
        cityLabel.isEmpty ||
        _resolvingGpsLabel) {
      final directory = await CityDirectory.load();
      final resolved = directory.resolveSelection(
        lat: _latitude!,
        lng: _longitude!,
        selectedCity: _selectedCity,
        languageCode: languageCode,
      );
      if (resolved.timezone == null ||
          resolved.timezone!.isEmpty ||
          resolved.label.isEmpty) {
        if (!mounted) return;
        // showSnackBar(
        //   context,
        //   AppLocalizations.of(context)!.tzResolveError,
        // );
        return;
      }
      timezone = resolved.timezone;
      cityLabel = resolved.label;
      if (mounted) {
        setState(() {
          _selectedCityLabel = cityLabel;
          _selectedTimezone = timezone;
          _resolvingGpsLabel = false;
        });
      }
    }

    final settings = PrayerSettings(
      latitude: _latitude!,
      longitude: _longitude!,
      timezone: timezone!,
      method: _selectedMethod,
      madhab: _selectedAsrCalc,
      highLatitudeRule: PrayerHighLatitudeRules.middleOfNight,
    );
    await SharedPreferencesService.instance.prayer.savePrayerSettings(
      latitude: _latitude!,
      longitude: _longitude!,
      method: _selectedMethod,
      asrCalculation: _selectedAsrCalc,
      timezone: timezone,
      city: _selectedCity,
      cityLabel: cityLabel,
    );
    if (!mounted) return;
    ref.read(prayerConfigProvider.notifier).publish(settings, cityLabel);
    // showSnackBar(context, AppLocalizations.of(context)!.settingsSaved);
    widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A locale switch mid-edit re-derives the in-flight label (a pick falls
    // back to its City in the new locale, GPS re-resolves), so saving
    // afterwards can never persist a stale-language string.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ---- 1. Location ----
        Text(
          "الموقع",
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        CityPickerField(
          selected: _selectedCity,
          selectedLabel: _resolvingGpsLabel ? "..." : _selectedCityLabel,
          onSelected: _onCitySelected,
        ),
        const SizedBox(height: 8),
        if (_showLocationError)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              "الرجاء اختيار موقع",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.colorScheme.error,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        const Divider(height: 24),

        // ---- 2. Asr madhab ----
        AsrCalcSegmentedButton(
          value: _selectedAsrCalc,
          onChanged: (data) => setState(() => _selectedAsrCalc = data),
        ),

        const Divider(height: 24),

        // ---- 3. Calculation method ----
        CalcMethodDropDown(
          value: _selectedMethod,
          onChanged: (value) => setState(() => _selectedMethod = value),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            if (widget.showCancel) ...[
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text("إلغاء"),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: ElevatedButton(
                onPressed: _saveSettings,
                child: Text("حفظ"),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
