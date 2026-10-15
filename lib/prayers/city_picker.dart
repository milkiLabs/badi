// city_picker.dart
//
// Searchable offline city picker used in [PrayerSettingsDialog].
//
// [CityPickerField] shows the current selection (or a placeholder) and
// opens [CitySearchSheet]: a bottom sheet with a search field and a
// virtualized [ListView.builder] of matches

import 'dart:async';

import 'package:badi/prayers/city.dart';
import 'package:badi/prayers/city_directory.dart';
import 'package:material_ui/material_ui.dart';

/// Field that expands an inline search panel under itself.
class CityPickerField extends StatefulWidget {
  const CityPickerField({
    required this.selected,
    required this.onSelected,
    this.selectedLabel,
    super.key,
  });

  final City? selected;
  final String? selectedLabel;
  final ValueChanged<({City city, String label})> onSelected;

  @override
  State<CityPickerField> createState() => _CityPickerFieldState();
}

class _CityPickerFieldState extends State<CityPickerField> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final languageCode = Localizations.localeOf(context).languageCode;
    final display = widget.selectedLabel?.isNotEmpty == true
        ? widget.selectedLabel!
        : widget.selected?.displayNameFor(languageCode);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          icon: Icon(_expanded ? Icons.expand_less : Icons.search),
          label: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              display ?? "ابحث عن مدينتك",
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: display == null
                    ? theme.hintColor
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
          style: OutlinedButton.styleFrom(
            alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          ),
          onPressed: () => setState(() => _expanded = !_expanded),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: _expanded
              ? Container(
                  height: 320,
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  // Built only while expanded, so the directory is loaded
                  // per open and dropped on close, as before.
                  child: CitySearchPanel(
                    initial: widget.selected,
                    onPicked: (picked) {
                      setState(() => _expanded = false);
                      widget.onSelected(picked);
                    },
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// Search field on top, virtualized results below. No sheet chrome.
class CitySearchPanel extends StatefulWidget {
  const CitySearchPanel({super.key, this.initial, required this.onPicked});

  final City? initial;
  final ValueChanged<({City city, String label})> onPicked;

  @override
  State<CitySearchPanel> createState() => _CitySearchPanelState();
}

class _CitySearchPanelState extends State<CitySearchPanel> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';

  /// Loaded once per sheet open, discarded on close (no cache).
  late final Future<CityDirectory> _future = CityDirectory.load();

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchController,
          autofocus: true,
          onChanged: _onQueryChanged,
          decoration: const InputDecoration(
            hintText: "ابحث عن مدينتك",
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: FutureBuilder<CityDirectory>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              }
              if (snapshot.hasError || !snapshot.hasData) {
                return Center(
                  child: Text(
                    "حدث خطأ أثناء تحميل قائمة المدن. يرجى المحاولة مرة أخرى.",
                  ),
                );
              }
              return _ResultsList(
                  directory: snapshot.data!,
                  query: _query,
                  initial: widget.initial,
                  onPicked: widget.onPicked);
            },
          ),
        ),
      ],
    );
  }
}

class _ResultsList extends StatelessWidget {
  const _ResultsList({
    required this.directory,
    required this.query,
    required this.initial,
    required this.onPicked,
  });

  /// Kept in sync with [CityDirectory.search]'s default limit.
  static const _searchLimit = 60;

  final CityDirectory directory;
  final String query;
  final City? initial;
  final ValueChanged<({City city, String label})> onPicked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Blank query lists every city (population order); typing filters via
    // the ranked search. Both paths share one virtualized list.
    final List<City> results;
    if (normalizeArabic(query).isEmpty) {
      results = directory.cities;
    } else {
      results = directory.search(query);
      if (results.isEmpty) {
        return Center(
          child: Text("لا توجد نتائح"),
        );
      }
    }
    final truncated =
        results.length >= _searchLimit && normalizeArabic(query).isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (truncated)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              "عرض ${results.length} من النتائج. يرجى تحسين البحث.",
              textAlign: TextAlign.center,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ),
        Expanded(
          // Virtualized: only visible rows are built, regardless of how
          // many cities match.
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (context, index) {
              final city = results[index];
              final isSelected = initial != null &&
                  initial!.latitude == city.latitude &&
                  initial!.longitude == city.longitude &&
                  initial!.nameEn == city.nameEn;
              final languageCode = Localizations.localeOf(context).languageCode;
              final title = city.displayNameFor(languageCode);
              // Secondary name in the other script when one exists.
              final altName = languageCode == 'ar' ? city.nameEn : city.nameAr;
              // List separator follows the UI locale; city/country names
              // stay in their database form (proper nouns).
              final separator = languageCode == 'en' ? ', ' : '، ';
              final subtitle = [
                if (altName != null && altName != title) altName,
                directory.countryLabelFor(city.countryCode, languageCode),
              ].join(separator);
              return ListTile(
                title: Text(title),
                subtitle: Text(subtitle),
                trailing: isSelected ? const Icon(Icons.check) : null,
                onTap: () => onPicked((
                  city: city,
                  label: directory.cityLabelFor(city, languageCode),
                )),
              );
            },
          ),
        ),
      ],
    );
  }
}
