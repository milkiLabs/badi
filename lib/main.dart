// Badi entrypoint: one binary, two roles.
//
//   badi             Long-lived shell for autostart: top bar always visible,
//                    launcher hidden until asked. Serves single-instance IPC.
//   badi --launcher  Open the launcher via the running daemon, or one-shot
//                    when no daemon is listening. Supports piped stdin
//                    (`find / | badi --launcher`) in dmenu mode.
//
// Requires Flutter channel `main` with windowing enabled:
//   flutter channel main
//   flutter upgrade
//   flutter config --enable-windowing
//
// Run only on a Wayland compositor that implements zwlr_layer_shell_v1
// (Sway/Hyprland/wlroots, KDE-Wayland, Miriway). Not supported on
// GNOME-Wayland or X11. System dependency: libgtk-layer-shell-dev
// (linked via linux/CMakeLists.txt + linux/runner/CMakeLists.txt).

import 'dart:convert';
import 'dart:io';

import 'package:layer_shell/layer_shell.dart';
import 'package:material_ui/material_ui.dart';

import 'platform/ipc.dart';
import 'shell/shell_controller.dart';
import 'ui/shell.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'prayers/shared_pref.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln('Usage: badi [--launcher]');
    stdout.writeln(
        '  (no args) run the long-lived shell (top bar + launcher server)');
    stdout.writeln('  --launcher open the launcher via the running daemon,');
    stdout.writeln('             or one-shot when no daemon is listening.');
    await stdout.flush();
    exit(0);
  }

  // Legacy alias kept for compatibility: `--shell` used to request the bar.
  if (args.contains('--launcher')) {
    await _openLauncher();
    return;
  }

  if (args.contains('--shell')) {
    await _runShell();
    return;
  }

  // Default: the bar (long-lived shell). This makes `flutter run` (no args)
  // open the shell surface during development.
  await _runShell();
}

/// Client path: ask a running daemon to open the launcher, or fall back to
/// a one-shot window when none is listening. Pure dart:io, no Flutter init,
/// so keypress clients stay fast and piping works headless.
Future<void> _openLauncher() async {
  final piped = _readPipedLines();
  final outcome = await tryOpenViaDaemon(
    socketPath: ipcSocketPath(),
    piped: piped,
  );
  if (outcome != null) {
    if (outcome.resultLine != null) stdout.writeln(outcome.resultLine);
    if (outcome.error != null) stderr.writeln('badi: ${outcome.error}');
    await stdout.flush();
    exit(outcome.exitCode);
  }

  WidgetsFlutterBinding.ensureInitialized();
  // Installs ExtendedWindowingOwnerLinux globally. Must run once before
  // creating any LayershellWindowController.
  initLayerShell();
  runWidget(BadiOneShot(piped: piped));
}

Future<void> _runShell() async {
  WidgetsFlutterBinding.ensureInitialized();
  initLayerShell();

  // Same prerequisites the regular app's main does before runApp.
  await SharedPreferencesService.ensureInitialized();
  tzdata.initializeTimeZones();

  final shell = ShellController();
  try {
    await serveIpc(shell, ipcSocketPath());
  } on SocketException catch (e) {
    stderr.writeln('badi: cannot bind ${ipcSocketPath()}: $e');
    exit(1);
  }
  runWidget(ProviderScope(child: BadiShell(shell: shell)));
}

/// Piped input lines, or null when running attached to a terminal.
Stream<String>? _readPipedLines() {
  if (stdin.hasTerminal) return null;
  return stdin
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .where((l) => l.isNotEmpty);
}
