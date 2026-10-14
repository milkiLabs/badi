// Layer-shell entrypoint using Flutter's experimental Desktop Windowing API.
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

import 'ui/shell.dart';

/// Piped stdin (`find / | badi`) opens the line picker: lines stream into
/// the list live, Enter/click prints the line to stdout and exits 0. A
/// terminal (or an empty pipe) opens the app launcher. Dart owns stdin and
/// stdout, the selection cursor, and spawning; filtering lives in the Zig
/// session core, which grows incrementally per input batch.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Installs ExtendedWindowingOwnerLinux globally. Must run once before
  // creating any LayershellWindowController.
  initLayerShell();
  runWidget(BadiShell(piped: _readPipedLines()));
}

/// Piped input lines, or null when running attached to a terminal.
///
/// A non-terminal stdin may still be a dry supervised pipe (flutter run,
/// systemd, …) that never produces nor EOFs; the launcher controller treats
/// the first line as the pipe signal and falls back to apps on a grace
/// timeout. Kept here: one caller (above), ten lines, stdio belongs to the
/// composition root.
Stream<String>? _readPipedLines() {
  if (stdin.hasTerminal) return null;
  return stdin
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .where((l) => l.isNotEmpty);
}
