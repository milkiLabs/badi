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
//
// Controllers must be created inside the widget tree (State.initState),
// not in main(), so GTK windowing is fully up before the first surface
// is created. See https://github.com/mattkae/layer_shell.dart
// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter/widgets.dart';
import 'package:layer_shell/layer_shell.dart';

import 'zig.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Installs ExtendedWindowingOwnerLinux globally. Must run once before
  // creating any LayershellWindowController.
  initLayerShell();
  runWidget(const ZigShell());
}

/// Root widget driving one layer-shell surface (top panel).
class ZigShell extends StatefulWidget {
  const ZigShell({super.key});

  @override
  State<ZigShell> createState() => _ZigShellState();
}

class _ZigShellState extends State<ZigShell> {
  late final LayershellWindowController _panel;

  @override
  void initState() {
    super.initState();
    final monitor = listMonitors().firstOrNull;

    // Top bar: 56px tall, reserves 56px so maximized windows don't
    // draw underneath it. Change layer/anchors/size for dock,
    // side panel, overlay, or background usage.
    _panel = LayershellWindowController(
      layer: LayerShellLayer.top,
      anchorEdges: const [
        LayerShellEdge.top,
        LayerShellEdge.left,
        LayerShellEdge.right,
      ],
      keyboardMode: LayerShellKeyboardMode.none,
      height: 56,
      exclusiveZone: 56,
      monitor: monitor?.gdkMonitor,
      namespace: 'zig-fii-panel',
    );
  }

  @override
  void dispose() {
    _panel.destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ViewCollection(
      views: [
        LayerShellWindow(
          controller: _panel,
          child: const PanelBody(),
        ),
      ],
    );
  }
}

/// Panel content. Same Zig FFI logic as the old MaterialApp version,
/// laid out as a compact horizontal bar for a 56px layer-shell surface.
class PanelBody extends StatefulWidget {
  const PanelBody({super.key});

  @override
  State<PanelBody> createState() => _PanelBodyState();
}

class _PanelBodyState extends State<PanelBody> {
  String _result = 'calling Zig...';

  @override
  void initState() {
    super.initState();
    _callZig();
  }

  void _callZig() {
    try {
      final sum = zigLib.add(40, 2);
      setState(() => _result = 'Zig add(40, 2) = $sum');
    } catch (e) {
      setState(() => _result = 'Failed to load Zig lib: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF1E1E2E),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Text(
                'zig_fii',
                style: TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  _result,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFCDD6F4),
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _callZig,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF45475A),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Call Zig again',
                    style: TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
