import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

class BarBody extends StatefulWidget {
  const BarBody({super.key, required this.onOpenLauncher});

  final VoidCallback onOpenLauncher;

  @override
  State<BarBody> createState() => _BarBodyState();
}

class _BarBodyState extends State<BarBody> {
  late Timer _clockTimer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clock =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    return Material(
      color: AppColors.background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            GestureDetector(
              onTap: widget.onOpenLauncher,
              child: const MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text('Badi', style: AppTextStyles.rowTitle),
              ),
            ),
            const Spacer(),
            Text(clock, style: AppTextStyles.body),
          ],
        ),
      ),
    );
  }
}
