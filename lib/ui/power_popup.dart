import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'popup_window.dart';

/// Configuration for the power options popup.
const PopupWindowConfig powerPopupConfig = PopupWindowConfig(
  width: 240,
  height: 195,
  namespace: 'badi-power-popup',
);

/// One power action: label, icon, and the argv to spawn detached.
class _PowerOption {
  const _PowerOption(this.label, this.icon, this.argv);

  final String label;
  final IconData icon;
  final List<String> argv;
}

/// Systemd user-session power actions. `systemctl poweroff/reboot/suspend`
/// work without root for the console user; logout ends the login session
/// (falling back to the user's sessions when the session id is unknown).
List<_PowerOption> _powerOptions() {
  final session = Platform.environment['XDG_SESSION_ID'];
  final user = Platform.environment['USER'];
  final logout = session != null && session.isNotEmpty
      ? ['loginctl', 'terminate-session', session]
      : ['loginctl', 'terminate-user', if (user != null) user];
  return [
    const _PowerOption('Suspend', Icons.bedtime, ['systemctl', 'suspend']),
    const _PowerOption('Restart', Icons.refresh, ['systemctl', 'reboot']),
    const _PowerOption('Power off', Icons.power_settings_new, [
      'systemctl',
      'poweroff',
    ]),
    _PowerOption('Log out', Icons.logout, logout),
  ];
}

/// Hover popup listing suspend / restart / power off / log out. Each row
/// spawns its command detached, like app launches.
class PowerPopupContent extends StatelessWidget {
  const PowerPopupContent({super.key});

  Future<void> _run(List<String> argv) async {
    try {
      await Process.start(
        argv.first,
        argv.skip(1).toList(),
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      // Spawn failed (e.g. no systemctl); nothing useful to show here.
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = _powerOptions();
    // Transparent Material so ink effects have a Material ancestor to
    // paint on (same pattern as the wifi popup list).
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Power', style: AppTextStyles.rowTitle),
          const SizedBox(height: 8),
          for (final option in options)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _run(option.argv),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Row(
                  children: [
                    Icon(option.icon, size: 18, color: AppColors.body),
                    const SizedBox(width: 10),
                    Text(option.label, style: AppTextStyles.body),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
