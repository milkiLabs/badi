// Shell surfaces for the long-lived daemon (`badi --shell`) and the
// one-shot fallback (bare `badi` with no daemon listening).
//
// The daemon drives layer-shell surfaces via [ViewCollection]: an always-on
// top bar (exclusive zone, no keyboard), an on-demand centered launcher
// (overlay, exclusive keyboard), and an on-demand wifi popup (overlay, no
// keyboard) anchored under the wifi icon. Controllers are created inside
// the widget tree (State.initState / listeners), never in main(), so GTK
// windowing is fully up before the first surface is created.
// See https://github.com/mattkae/layer_shell.dart
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:layer_shell/layer_shell.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/shell_actions.dart';
import '../shell/shell_controller.dart';
import 'app_theme.dart';
import 'bar_page.dart';
import 'launcher_page.dart';
import 'wifi_popup.dart';

/// Shared dark theme for every shell surface. Each [LayerShellWindow] needs
/// its own [MaterialApp] (localizations, directionality, overlay per view).
Widget _surface({required Widget home}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark().copyWith(
      scaffoldBackgroundColor: AppColors.background,
    ),
    home: home,
  );
}

/// Long-lived shell: bar always visible, launcher shown per [shell].
class BadiShell extends StatefulWidget {
  const BadiShell({super.key, required this.shell});

  final ShellController shell;

  @override
  State<BadiShell> createState() => _BadiShellState();
}

class _BadiShellState extends State<BadiShell> {
  late final LayershellWindowController _bar;
  LayershellWindowController? _launcher;
  LayershellWindowController? _wifiPopup;
  Timer? _wifiHideTimer;
  bool _wifiHoveringIcon = false;
  bool _wifiHoveringPopup = false;

  @override
  void initState() {
    super.initState();
    final monitor = listMonitors().firstOrNull;
    // A 32px bar pinned to the top; the exclusive zone keeps maximized
    // windows out of the strip.
    _bar = LayershellWindowController(
      layer: LayerShellLayer.top,
      anchorEdges: const [
        LayerShellEdge.top,
        LayerShellEdge.left,
        LayerShellEdge.right,
      ],
      keyboardMode: LayerShellKeyboardMode.none,
      height: 32,
      exclusiveZone: 32,
      monitor: monitor?.gdkMonitor,
      namespace: 'badi-bar',
    );
    widget.shell.addListener(_syncLauncher);
    _syncLauncher();
  }

  /// Creates the overlay surface on open, destroys it on close. The
  /// launcher's picker state is keyed per request ([ShellController.generation])
  /// so a reopen never reuses a disposed controller's widget state.
  void _syncLauncher() {
    if (widget.shell.launcherOpen && _launcher == null) {
      final monitor = listMonitors().firstOrNull;
      _launcher = LayershellWindowController(
        autoExclusiveZone: true,
        layer: LayerShellLayer.overlay,
        anchorEdges: const [],
        keyboardMode: LayerShellKeyboardMode.exclusive,
        width: 480,
        height: 600,
        exclusiveZone: 0,
        monitor: monitor?.gdkMonitor,
        namespace: 'badi-launcher',
      );
      setState(() {});
    } else if (!widget.shell.launcherOpen && _launcher != null) {
      _launcher!.destroy();
      _launcher = null;
      setState(() {});
    }
  }

  void _openFromBar() {
    widget.shell.openApps(
      actions: ShellAppActions(onDone: widget.shell.closeLauncher),
    );
  }

  void _setWifiIconHover(bool hovering) {
    _wifiHoveringIcon = hovering;
    if (hovering) {
      _wifiHideTimer?.cancel();
      _wifiHideTimer = null;
      _showWifiPopup();
    } else {
      _scheduleHideWifiPopup();
    }
  }

  void _setWifiPopupHover(bool hovering) {
    _wifiHoveringPopup = hovering;
    if (hovering) {
      _wifiHideTimer?.cancel();
      _wifiHideTimer = null;
    } else {
      _scheduleHideWifiPopup();
    }
  }

  void _scheduleHideWifiPopup() {
    _wifiHideTimer?.cancel();
    _wifiHideTimer = Timer(const Duration(milliseconds: 200), () {
      if (!_wifiHoveringIcon && !_wifiHoveringPopup) {
        _hideWifiPopup();
      }
      _wifiHideTimer = null;
    });
  }

  void _showWifiPopup() {
    if (_wifiPopup != null) return;
    final monitor = listMonitors().firstOrNull;
    _wifiPopup = LayershellWindowController(
      layer: LayerShellLayer.overlay,
      anchorEdges: const [
        LayerShellEdge.top,
        LayerShellEdge.right,
      ],
      keyboardMode: LayerShellKeyboardMode.none,
      width: 220,
      height: 140,
      exclusiveZone: 0,
      monitor: monitor?.gdkMonitor,
      namespace: 'badi-wifi-popup',
    );
    setState(() {});
  }

  void _hideWifiPopup() {
    if (_wifiPopup == null) return;
    _wifiPopup!.destroy();
    _wifiPopup = null;
    _wifiHoveringIcon = false;
    _wifiHoveringPopup = false;
    setState(() {});
  }

  @override
  void dispose() {
    widget.shell.removeListener(_syncLauncher);
    _launcher?.destroy();
    _wifiPopup?.destroy();
    _wifiHideTimer?.cancel();
    _bar.destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final launcher = _launcher;
    final actions = widget.shell.currentActions;
    return ViewCollection(
      views: [
        LayerShellWindow(
          controller: _bar,
          child: _surface(
            home: BarBody(
              onOpenLauncher: _openFromBar,
              onWifiHover: () => _setWifiIconHover(true),
              onWifiExit: () => _setWifiIconHover(false),
            ),
          ),
        ),
        if (launcher != null && actions != null)
          LayerShellWindow(
            controller: launcher,
            child: _surface(
              home: LauncherBody(
                key: ValueKey(widget.shell.generation),
                piped: widget.shell.piped,
                actions: actions,
              ),
            ),
          ),
        if (_wifiPopup != null)
          LayerShellWindow(
            controller: _wifiPopup!,
            child: _surface(
              home: WifiPopup(onHoverChanged: _setWifiPopupHover),
            ),
          ),
      ],
    );
  }
}

/// One-shot picker used when no daemon is listening: a single overlay
/// window with the original exit semantics (`find / | badi` prints the
/// pick; plain `badi` launches the app). No bar, no IPC.
class BadiOneShot extends StatefulWidget {
  const BadiOneShot({super.key, this.piped});

  /// Piped input lines; null selects the app launcher.
  final Stream<String>? piped;

  @override
  State<BadiOneShot> createState() => _BadiOneShotState();
}

class _BadiOneShotState extends State<BadiOneShot> {
  late final LayershellWindowController _window;

  @override
  void initState() {
    super.initState();
    final monitor = listMonitors().firstOrNull;

    _window = LayershellWindowController(
      autoExclusiveZone: true,
      layer: LayerShellLayer.overlay,
      anchorEdges: const [],
      keyboardMode: LayerShellKeyboardMode.exclusive,
      width: 480,
      height: 600,
      exclusiveZone: 0,
      monitor: monitor?.gdkMonitor,
      namespace: 'badi-launcher',
    );
  }

  @override
  void dispose() {
    _window.destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ViewCollection(
      views: [
        LayerShellWindow(
          controller: _window,
          child: _surface(home: LauncherBody(piped: widget.piped)),
        ),
      ],
    );
  }
}
