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

import 'badi.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Installs ExtendedWindowingOwnerLinux globally. Must run once before
  // creating any LayershellWindowController.
  initLayerShell();
  runWidget(const BadiShell());
}

/// Root widget driving one centered layer-shell surface.
class BadiShell extends StatefulWidget {
  const BadiShell({super.key});

  @override
  State<BadiShell> createState() => _BadiShellState();
}

class _BadiShellState extends State<BadiShell> {
  late final LayershellWindowController _window;

  @override
  void initState() {
    super.initState();
    final monitor = listMonitors().firstOrNull;

    // Centered floating window: no anchor edges + explicit size makes the
    // compositor place it in the middle of the screen. exclusiveZone 0 so
    // it reserves no space for maximized windows.
    _window = LayershellWindowController(
      layer: LayerShellLayer.overlay,
      anchorEdges: const [],
      keyboardMode: LayerShellKeyboardMode.onDemand,
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
          child: const AppListBody(),
        ),
      ],
    );
  }
}

/// Simple record for one row of the list.
class _AppItem {
  const _AppItem({required this.name, required this.exec});
  final String name;
  final String exec;
}

/// Centered window content: a header plus a scrollable list of installed apps.
class AppListBody extends StatefulWidget {
  const AppListBody({super.key});

  @override
  State<AppListBody> createState() => _AppListBodyState();
}

class _AppListBodyState extends State<AppListBody> {
  List<_AppItem>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      final apps = BadiApps.scan();
      try {
        final items = <_AppItem>[
          for (final app in apps.apps)
            _AppItem(name: app.name, exec: app.exec),
        ];
        setState(() {
          _items = items;
          _error = null;
        });
      } finally {
        apps.close();
      }
    } catch (e) {
      setState(() {
        _items = null;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF1E1E2E),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _items == null && _error == null
                    ? 'Loading…'
                    : '${_items?.length ?? 0} applications',
                style: const TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return SingleChildScrollView(
        child: Text(
          'Failed to load applications: $_error',
          style: const TextStyle(color: Color(0xFFF38BA8), fontSize: 13),
        ),
      );
    }
    final items = _items;
    if (items == null) {
      return const Center(
        child: Text(
          'Loading…',
          style: TextStyle(color: Color(0xFFCDD6F4), fontSize: 13),
        ),
      );
    }
    if (items.isEmpty) {
      return const Center(
        child: Text(
          'No applications found',
          style: TextStyle(color: Color(0xFFCDD6F4), fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      itemCount: items.length,
      itemExtent: 56,
      itemBuilder: (context, i) {
        final item = items[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ColoredBox(
            color: const Color(0xFF313244),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (item.exec.isNotEmpty)
                    Text(
                      item.exec,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFA6ADC8),
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
