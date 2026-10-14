import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'activate.dart';
import 'app_icon.dart';
import 'batch.dart';
import 'session.dart';

/// Launcher content: search field on top, virtualized selectable list.
/// Pure UI: filtering, selection, and launch all live in the Zig backend
/// ([Session]); this only renders rows and forwards events. In pipe mode
/// (`piped != null`) rows stream in from stdin and activating one completes
/// via [LauncherActions]; otherwise rows are installed applications.
///
/// Never calls `exit()` directly: completion and cancellation go through
/// [actions] (defaults to [processLauncherActions]).
class LauncherBody extends StatefulWidget {
  const LauncherBody({
    super.key,
    this.piped,
    this.actions = processLauncherActions,
  });

  final Stream<String>? piped;

  /// Completion/cancellation handler. Inject a fake in widget tests to
  /// assert activation without exiting the test process.
  final LauncherActions actions;

  @override
  State<LauncherBody> createState() => _LauncherBodyState();
}

class _LauncherBodyState extends State<LauncherBody> {
  Session? _s;
  int _count = 0;
  String? _error;
  bool _loading = true;
  int _selected = 0;
  String? _actionError;

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
        widget.actions.cancel(pipeMode: _pipeMode);
        return KeyEventResult.handled;
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

  /// Forward the activation to [LauncherActions]: pipe mode prints the
  /// line, apps mode spawns. Failures surface as an error row; success
  /// exits inside the actions implementation.
  Future<void> _activate(int i) async {
    final s = _s;
    if (s == null) return;
    if (_pipeMode) {
      try {
        await widget.actions.completeWithLine(s.result(i));
      } catch (e) {
        if (mounted) setState(() => _actionError = 'Failed to print selection: $e');
      }
      return;
    }
    try {
      await widget.actions.completeWithApp(s, i);
    } catch (e) {
      if (mounted) setState(() => _actionError = 'Failed to launch: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
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
              _actionError ??
                  (_loading
                      ? 'Loading…'
                      : _pipeMode
                          ? (_streamDone
                              ? '$_count lines'
                              : '$_count lines…')
                          : '$_count applications'),
              style: TextStyle(
                color: _actionError != null
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
                      child: AppIcon(
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
