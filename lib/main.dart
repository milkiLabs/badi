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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';
import 'package:layer_shell/layer_shell.dart';

import 'batch.dart';
import 'session.dart';

/// Piped stdin (`find / | badi`) opens the line picker: lines stream into
/// the list live, Enter/click prints the line to stdout and exits 0. A
/// terminal (or an empty pipe) opens the app launcher. Dart owns stdin and
/// stdout here; filtering, selection, and launching live in the Zig
/// session core, which grows incrementally per input batch.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Installs ExtendedWindowingOwnerLinux globally. Must run once before
  // creating any LayershellWindowController.
  initLayerShell();
  runWidget(BadiShell(
    piped: stdin.hasTerminal
        ? null
        : stdin
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .where((l) => l.isNotEmpty),
  ));
}

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
                      builder: (_) => LauncherBody(piped: widget.piped),
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

/// Launcher content: search field on top, virtualized selectable list.
/// Pure UI: filtering, selection, and launch all live in the Zig backend
/// ([Session]); this only renders rows and forwards events. In pipe mode
/// (`piped != null`) rows stream in from stdin and activating one prints
/// it to stdout; otherwise rows are installed applications.
class LauncherBody extends StatefulWidget {
  const LauncherBody({super.key, this.piped});

  final Stream<String>? piped;

  @override
  State<LauncherBody> createState() => _LauncherBodyState();
}

class _LauncherBodyState extends State<LauncherBody> {
  Session? _s;
  int _count = 0;
  String? _error;
  bool _loading = true;
  int _selected = 0;
  String? _launchError;

  /// Pipe mode is event-driven: first piped line flips it on (see _onLine).
  /// A dry pipe (flutter run, systemd, …) never produces, so the grace
  /// timer falls back to apps instead of hanging on "No match" forever.
  bool _pipeMode = false;
  bool _streamDone = false;
  Timer? _grace;
  StreamSubscription<String>? _sub;
  Batcher<String>? _batcher;

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
    unawaited(_sub?.cancel());
    _sub = null;
    _grace?.cancel();
    _grace = null;
    _batcher = null; // drop leftovers: flushing here could setState mid-dispose
    _query.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    _s?.close();
    super.dispose();
  }

  void _load() {
    if (widget.piped == null) {
      _enterApps(); // terminal: apps immediately, no subscription
      return;
    }
    // Pipe-ish stdin: wait for the first signal instead of assuming data.
    // Real pipes produce in milliseconds; the grace timer rescues dry
    // supervised stdin (which never EOFs) without stalling real input.
    _grace = Timer(const Duration(milliseconds: 200), _onGraceTimeout);
    _sub = widget.piped!.listen(
      _onLine,
      onError: _onStreamError,
      onDone: () => _onStreamDone(),
    );
  }

  /// One input line arrived. The first line decides pipe mode; the rest
  /// stream through the batcher. Also fires for slow pipes after the apps
  /// fallback already painted (late flip, same path).
  void _onLine(String line) {
    if (_pipeMode) {
      _batcher!.add(line);
      return;
    }
    _enterPipe(line);
  }

  /// Open the picker on the first piped line. Replaces the apps session on
  /// a late flip; re-applies any query typed meanwhile.
  void _enterPipe(String first) {
    _pipeMode = true;
    _grace?.cancel();
    _grace = null;
    try {
      final s = Session.lines([first]);
      _s?.close();
      _s = s;
      _batcher = Batcher<String>(
        size: 500,
        idle: const Duration(milliseconds: 100),
        onBatch: _onBatch,
      );
      final q = _query.text;
      setState(() {
        if (q.isNotEmpty) s.setQuery(q);
        _count = s.length;
        _selected = s.selected;
        _loading = false;
      });
    } catch (e) {
      _pipeMode = false; // back to a consistent state: no pipe session open
      unawaited(_sub?.cancel());
      _sub = null;
      _batcher = null;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// Open the app launcher: terminal path, empty pipe at EOF, or grace
  /// timeout on a dry pipe. Keeps listening: slow-pipe data still flips
  /// to the picker via _onLine.
  void _enterApps() {
    try {
      final s = Session.apps();
      _s?.close();
      _s = s;
      setState(() {
        _count = s.length;
        _selected = s.selected;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _onGraceTimeout() {
    _grace = null;
    if (!_pipeMode) _enterApps();
  }

  /// One input batch arrived: extend the session, refresh the view.
  /// Selection is untouched by appends (Zig side), so only counts sync.
  void _onBatch(List<String> batch) {
    final s = _s;
    if (s == null || !mounted) return;
    setState(() {
      s.append(batch);
      _count = s.length;
      _selected = s.selected;
    });
  }

  void _onStreamError(Object _, StackTrace __) => _onStreamDone();

  Future<void> _onStreamDone() async {
    if (_sub == null) return; // error and done both fire: run once
    await _sub?.cancel();
    _sub = null;
    _grace?.cancel();
    _grace = null;
    _batcher?.close(); // flush leftovers through _onBatch
    _batcher = null;
    if (!mounted) return;
    if (!_pipeMode && _s == null) {
      _enterApps(); // EOF with zero data: show apps
      return;
    }
    setState(() {
      _streamDone = true;
    });
  }

  void _onQuery(String text) {
    final s = _s;
    if (s == null) return;
    setState(() {
      s.setQuery(text);
      _count = s.length;
      _selected = s.selected;
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
        if (_count > 0) {
          _activate(_selected.clamp(0, _count - 1));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        exit(_pipeMode ? 1 : 0);
    }
    return KeyEventResult.ignored;
  }

  void _move(int delta) {
    final s = _s;
    if (s == null || _count == 0) return;
    setState(() {
      s.move(delta);
      _selected = s.selected;
    });
    // itemExtent is 56: keep the selection visible.
    if (_scroll.hasClients) {
      final offset = _selected * 56.0;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(offset.clamp(0.0, max));
    }
  }

  /// Apps mode: spawn and exit. Pipe mode: print the line and exit 0.
  /// `exit` never flushes stdout on its own, so flush first.
  Future<void> _activate(int i) async {
    final s = _s;
    if (s == null) return;
    if (_pipeMode) {
      stdout.writeln(s.result(i));
      await stdout.flush();
      exit(0);
    }
    try {
      s.launch(i);
    } catch (e) {
      if (mounted) setState(() => _launchError = 'Failed to launch: $e');
      return;
    }
    exit(0);
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
              decoration: InputDecoration(
                hintText: _pipeMode ? 'Filter…' : 'Search applications…',
                hintStyle: TextStyle(color: Color(0xFF6C7086), fontSize: 14),
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _launchError ??
                  (_loading
                      ? 'Loading…'
                      : _pipeMode
                          ? (_streamDone
                              ? '$_count lines'
                              : '$_count lines…')
                          : '$_count applications'),
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
          _pipeMode ? 'Failed to load input: $_error' : 'Failed to load applications: $_error',
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
    if (_count == 0) {
      return const Center(
        child: Text(
          'No match',
          style: TextStyle(color: Color(0xFFCDD6F4), fontSize: 13),
        ),
      );
    }
    final s = _s!;
    // Builder only builds visible rows: virtualized for long lists.
    return ListView.builder(
      controller: _scroll,
      itemCount: _count,
      itemExtent: 56,
      itemBuilder: (context, i) {
        final item = s.rowAt(i);
        final selected = i == _selected;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: GestureDetector(
            onTap: () => _activate(i),
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
                        fallback: item.title,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFFFFFFF),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if ((item.subtitle ?? '').isNotEmpty)
                            Text(
                              item.subtitle!,
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
