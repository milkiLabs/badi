// Layer-shell surface for the launcher. Owns the window controller
// the picker UI itself lives in [LauncherBody].
//
// Controllers must be created inside the widget tree (State.initState),
// not in main(), so GTK windowing is fully up before the first surface
// is created. See https://github.com/mattkae/layer_shell.dart

import 'package:layer_shell/layer_shell.dart';
import 'package:material_ui/material_ui.dart';

import 'launcher_body.dart';

/// Root widget driving one centered layer-shell surface.
class BadiShell extends StatefulWidget {
  const BadiShell({super.key, this.piped});

  /// Piped input lines; null selects the app launcher.
  final Stream<String>? piped;

  @override
  State<BadiShell> createState() => _BadiShellState();
}

class _BadiShellState extends State<BadiShell> {
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
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark().copyWith(
              scaffoldBackgroundColor: const Color(0xFF1E1E2E),
            ),
            home: LauncherBody(piped: widget.piped),
          ),
        ),
      ],
    );
  }
}
