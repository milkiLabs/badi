import 'dart:io';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

/// 36px app picture: the resolved icon file, or the app's initial letter.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.iconPath, required this.fallback});

  final String? iconPath;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final p = iconPath;
    if (p != null) {
      if (p.toLowerCase().endsWith('.svg')) {
        return SvgPicture.file(
          File(p),
          width: 36,
          height: 36,
          placeholderBuilder: (_) => _placeholder(),
        );
      }
      return Image.file(
        File(p),
        width: 36,
        height: 36,
        errorBuilder: (context, error, stackTrace) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    final letter = fallback.trim().isEmpty ? '?' : fallback.trim()[0];
    return ColoredBox(
      color: AppColors.selectedRow,
      child: Center(
        child: Text(
          letter.toUpperCase(),
          style: AppTextStyles.placeholderLetter,
        ),
      ),
    );
  }
}
