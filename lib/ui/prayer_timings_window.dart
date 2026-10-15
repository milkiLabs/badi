import 'package:badi/prayers/provider.dart';
import 'package:badi/ui/prayer_screen/prayer_header_card.dart';
import 'package:badi/ui/prayer_screen/prayer_timings_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PrayerTimingsScreen extends ConsumerStatefulWidget {
  const PrayerTimingsScreen({super.key});

  @override
  ConsumerState<PrayerTimingsScreen> createState() =>
      _PrayerTimingsScreenState();
}

class _PrayerTimingsScreenState extends ConsumerState<PrayerTimingsScreen> {
  @override
  Widget build(BuildContext context) {
    // If the view is still null on build (e.g. settings cleared while away),
    // schedule the one-time setup prompt. No listener: build already reruns
    // on every view change.
    ref.watch(prayerViewProvider);
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          PrayerHeaderCard(),
          SizedBox(height: 8),
          PrayerTimingsCard(),
        ],
      ),
    );
  }
}

// /// Bell icon owning its own enabled flag
// class _NotifBell extends ConsumerStatefulWidget {
//   const _NotifBell();
//
//   @override
//   ConsumerState<_NotifBell> createState() => _NotifBellState();
// }
//
// class _NotifBellState extends ConsumerState<_NotifBell> {
//   bool _enabled = false;
//
//   @override
//   void initState() {
//     super.initState();
//     unawaited(isPrayerNotificationEnabled().then((value) {
//       if (mounted) setState(() => _enabled = value);
//     }));
//   }
//
//   Future<void> _refresh() async {
//     final value = await isPrayerNotificationEnabled();
//     if (mounted) setState(() => _enabled = value);
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     // Single source of truth: the derived view. No separate schedule fetch.
//     final configured = ref.watch(prayerViewProvider) != null;
//     return IconButton(
//       tooltip: "إشعارات مواقيت الصلاة",
//       icon: Icon(
//         _enabled ? Icons.notifications_active : Icons.notifications_off,
//       ),
//       onPressed: () async {
//         // No timings yet (settings never saved) → prompt to set
//         // them up first instead of the notification explainer.
//         if (!configured) {
//           final openSettings = await showDialog<bool>(
//             context: context,
//             builder: (context) => const PrayerSetupRequiredDialog(),
//           );
//           if (openSettings == true && context.mounted) {
//             await showDialog<void>(
//               context: context,
//               builder: (context) => const PrayerSettingsDialog(),
//             );
//           }
//           return;
//         }
//         if (_enabled) {
//           // On → off straight away, no dialog.
//           await setPrayerNotificationEnabled(false);
//           await _refresh();
//           return;
//         }
//         // Off → explain first, then enable from the dialog.
//         final changed = await showDialog<bool>(
//           context: context,
//           builder: (context) => const PrayerNotificationDialog(),
//         );
//         // Refresh the bell icon when the dialog changed anything.
//         if (changed == true) await _refresh();
//       },
//     );
//   }
// }
