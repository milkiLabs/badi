import 'package:material_ui/material_ui.dart';

/// Catppuccin-mocha palette + text styles for the launcher. Centralized so
/// widgets never hardcode hex values.
class AppColors {
  AppColors._();

  static const background = Color(0xFF1E1E2E);
  static const selectedRow = Color(0xFF45475A);
  static const row = Color(0xFF313244);
  static const title = Color(0xFFFFFFFF);
  static const subtitle = Color(0xFFA6ADC8);
  static const hint = Color(0xFF6C7086);
  static const error = Color(0xFFF38BA8);
  static const body = Color(0xFFCDD6F4);
}

class AppTextStyles {
  AppTextStyles._();

  static const input = TextStyle(color: AppColors.title, fontSize: 14);
  static const hint = TextStyle(color: AppColors.hint, fontSize: 14);
  static const status = TextStyle(color: AppColors.subtitle, fontSize: 12);
  static const statusError = TextStyle(color: AppColors.error, fontSize: 12);
  static const body = TextStyle(color: AppColors.body, fontSize: 13);
  static const rowTitle = TextStyle(
    color: AppColors.title,
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );
  static const rowSubtitle = TextStyle(color: AppColors.subtitle, fontSize: 11);
  static const placeholderLetter = TextStyle(
    color: AppColors.body,
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );
}
