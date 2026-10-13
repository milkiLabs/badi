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

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';
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
    // Keyboard is exclusive (not onDemand): a launcher must own keyboard
    // focus as soon as it opens, otherwise the compositor waits for a
    // click/hover before sending keys and autofocus never fires.
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
    // Bare runWidget tree: no MaterialApp, so provide here what it normally
    // would — localizations for TextField, direction, and an Overlay for the
    // text editing layer. Kept above the Overlay so floating followers
    // (selection toolbar) resolve them too.
    return ViewCollection(
      views: [
        LayerShellWindow(
          controller: _window,
          child: Localizations(
            locale: const Locale('en'),
            delegates: GlobalMaterialLocalizations.delegates,
            child: Directionality(
              textDirection: TextDirection.ltr,
              // Provides the standard editing keys (backspace/delete,
              // ctrl+a/c/v/x, …). Normally inserted by WidgetsApp/MaterialApp;
              // without it Backspace does nothing while typing still works,
              // because characters arrive via the IME channel, not key events.
              child: DefaultTextEditingShortcuts(
                child: Overlay(
                  initialEntries: [
                    OverlayEntry(
                      builder: (_) => const LauncherBody(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Launcher content: search field on top, virtualized selectable app list.
/// Pure UI: listing, search, and launch all live in the Zig backend
/// ([BadiApps]); this only renders rows and forwards events.
class LauncherBody extends StatefulWidget {
  const LauncherBody({super.key});

  @override
  State<LauncherBody> createState() => _LauncherBodyState();
}

class _LauncherBodyState extends State<LauncherBody> {
  BadiApps? _db;
  List<BadiApp> _shown = const [];
  String? _error;
  bool _loading = true;
  int _selected = 0;
  String? _launchError;

  late final TextEditingController _query;
  late final FocusNode _searchFocus;
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController();
    _searchFocus = FocusNode(onKeyEvent: _handleKey);
    _scroll = ScrollController();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    _db?.close();
    super.dispose();
  }

  void _load() {
    try {
      final db = BadiApps.scan();
      setState(() {
        _db = db;
        _shown = db.apps;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _onQuery(String text) {
    final db = _db;
    if (db == null) return;
    setState(() {
      _shown = db.search(text);
      _selected = 0;
    });
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    // Held keys arrive as KeyRepeatEvent, not KeyDownEvent — accept both
    // or holding an arrow moves only one row.
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
        if (_shown.isNotEmpty) {
          _launch(_shown[_selected.clamp(0, _shown.length - 1)]);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        exit(0);
    }
    return KeyEventResult.ignored;
  }

  void _move(int delta) {
    if (_shown.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, _shown.length - 1);
    });
    // itemExtent is 56: keep the selection visible.
    if (_scroll.hasClients) {
      final offset = _selected * 56.0;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(offset.clamp(0.0, max));
    }
  }

  void _launch(BadiApp app) {
    _logLaunch('tap ${app.name} [${app.index}]');
    try {
      _db?.launch(app.index);
    } catch (e) {
      _logLaunch('fail ${app.name}: $e');
      if (mounted) setState(() => _launchError = 'Failed to launch: $e');
      return;
    }
    _logLaunch('spawned ${app.name} ok, exiting');
    exit(0);
  }

  void _logLaunch(String line) {
    try {
      File('/tmp/badi-launcher.log').writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // Logging must never break launching.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Localizations/Directionality/Overlay come from the window level above.
    return Material(
      color: const Color(0xFF1E1E2E),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _query,
              focusNode: _searchFocus,
              autofocus: true,
              onChanged: _onQuery,
              cursorColor: const Color(0xFFFFFFFF),
              style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 14),
              decoration: const InputDecoration(
                hintText: 'Search applications…',
                hintStyle: TextStyle(color: Color(0xFF6C7086), fontSize: 14),
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _launchError ??
                  (_loading ? 'Loading…' : '${_shown.length} applications'),
              style: TextStyle(
                color: _launchError != null
                    ? const Color(0xFFF38BA8)
                    : const Color(0xFFA6ADC8),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildBody()),
          ],
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
    if (_loading) {
      return const Center(
        child: Text(
          'Loading…',
          style: TextStyle(color: Color(0xFFCDD6F4), fontSize: 13),
        ),
      );
    }
    if (_shown.isEmpty) {
      return const Center(
        child: Text(
          'No match',
          style: TextStyle(color: Color(0xFFCDD6F4), fontSize: 13),
        ),
      );
    }
    // Builder only builds visible rows: virtualized for long lists.
    return ListView.builder(
      controller: _scroll,
      itemCount: _shown.length,
      itemExtent: 56,
      itemBuilder: (context, i) {
        final item = _shown[i];
        final selected = i == _selected;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: GestureDetector(
            onTap: () => _launch(item),
            child: ColoredBox(
              color:
                  selected ? const Color(0xFF45475A) : const Color(0xFF313244),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: _AppIcon(
                        iconPath: item.iconPath,
                        fallback: item.name,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
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
                          if ((item.comment ?? '').isNotEmpty)
                            Text(
                              item.comment!,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFA6ADC8),
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 36px app picture: the resolved icon file, or the app's initial letter.
class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.iconPath, required this.fallback});

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
      color: const Color(0xFF45475A),
      child: Center(
        child: Text(
          letter.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFFCDD6F4),
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
