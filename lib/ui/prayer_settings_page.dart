import 'package:badi/prayers/settings_form.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

/// Full-surface page hosting [PrayerSettingsForm] inside the clock popup.
class PrayerSettingsPage extends StatelessWidget {
  const PrayerSettingsPage({super.key, this.onHoverChanged});

  final ValueChanged<bool>? onHoverChanged;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onHoverChanged?.call(true),
      onExit: (_) => onHoverChanged?.call(false),
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          title: Text('إعدادات مواقيت الصلاة', style: AppTextStyles.rowTitle),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: PrayerSettingsForm(
            showCancel: false,
            onSaved: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
}
