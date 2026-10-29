import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/actions.dart';
import '../core/launcher_controller.dart';
import '../core/session.dart';
import '../platform/process_actions.dart';
import '../platform/zig.dart';
import 'app_theme.dart';

/// Launcher content: search field on top, virtualized selectable list.
/// Pure view over [LauncherController]: renders state, forwards input.
/// Keeps only text/scroll/focus controllers; session, streams, cursor, and
/// completion live in the controller/actions.
class LauncherBody extends StatefulWidget {
  const LauncherBody({
    super.key,
    this.piped,
    this.actions = processLauncherActions,
    this.controller,
  });

  final Stream<dynamic>? piped;

  /// Completion/cancellation handler. Inject a fake in widget tests to
  /// assert activation without exiting the test process.
  final LauncherActions actions;

  /// Injected controller (tests). When null, one is created from [piped]
  /// and [actions] and disposed with the widget.
  final LauncherController? controller;

  @override
  State<LauncherBody> createState() => _LauncherBodyState();
}

class _LauncherBodyState extends State<LauncherBody> {
  late final LauncherController _controller;
  bool _ownsController = false;

  late final TextEditingController _query;
  late final FocusNode _searchFocus;
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller!;
    } else {
      // Composition: bind the real session factories to the loaded library.
      // Tests inject a controller with fakes instead.
      _controller = LauncherController(
        actions: widget.actions,
        piped: widget.piped,
        openApps: () => Session.apps(lib: badiLib),
        openLines: (first) => Session.lines([first], lib: badiLib),
      );
      _ownsController = true;
    }
    _query = TextEditingController();
    _searchFocus = FocusNode(onKeyEvent: _handleKey);
    _scroll = ScrollController();
    _controller.attach();
  }

  @override
  void dispose() {
    _controller.detach();
    if (_ownsController) _controller.dispose();
    _query.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
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
        final count = _controller.count;
        if (count > 0) {
          unawaited(
            _controller.activate(_controller.selected.clamp(0, count - 1)),
          );
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        _controller.cancel();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int delta) {
    _controller.move(delta);
    // itemExtent is 56: keep the selection visible.
    if (_scroll.hasClients) {
      final offset = _controller.selected * 56.0;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(offset.clamp(0.0, max));
    }
  }

  void _onQuery(String text) {
    _controller.setQuery(text);
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final count = _controller.count;
        final selected = _controller.selected;
        final actionError = _controller.actionError;
        final loading = _controller.loading;
        final pipeMode = _controller.pipeMode;
        final streamDone = _controller.streamDone;
        final error = _controller.error;
        return Material(
          color: AppColors.background,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Shortcuts(
                  // Ctrl+W deletes a word, exactly like Ctrl+Backspace:
                  // same intent, same word-boundary logic, shift-insensitive
                  // like the framework binding.
                  shortcuts: <ShortcutActivator, Intent>{
                    for (final shift in <bool>[false, true])
                      SingleActivator(
                        LogicalKeyboardKey.keyW,
                        control: true,
                        shift: shift,
                      ): const DeleteToNextWordBoundaryIntent(forward: false),
                  },
                  child: TextField(
                    controller: _query,
                    focusNode: _searchFocus,
                    autofocus: true,
                    onChanged: _onQuery,
                    cursorColor: AppColors.title,
                    style: AppTextStyles.input,
                    decoration: InputDecoration(
                      hintText: pipeMode ? 'Filter…' : 'Search applications…',
                      hintStyle: AppTextStyles.hint,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  actionError ??
                      (loading
                          ? 'Loading…'
                          : pipeMode
                              ? (streamDone ? '$count lines' : '$count lines…')
                              : '$count applications'),
                  style: actionError != null
                      ? AppTextStyles.statusError
                      : AppTextStyles.status,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _buildBody(
                    error: error,
                    loading: loading,
                    count: count,
                    selected: selected,
                    pipeMode: pipeMode,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody({
    required String? error,
    required bool loading,
    required int count,
    required int selected,
    required bool pipeMode,
  }) {
    if (error != null) {
      return SingleChildScrollView(
        child: Text(
          pipeMode
              ? 'Failed to load input: $error'
              : 'Failed to load applications: $error',
          style: AppTextStyles.statusError,
        ),
      );
    }
    if (loading) {
      return const Center(
        child: Text('Loading…', style: AppTextStyles.body),
      );
    }
    if (count == 0) {
      return const Center(
        child: Text('No match', style: AppTextStyles.body),
      );
    }
    // Builder only builds visible rows: virtualized for long lists.
    return ListView.builder(
      controller: _scroll,
      itemCount: count,
      itemExtent: 56,
      itemBuilder: (context, i) {
        final item = _controller.rowAt(i);
        final isSelected = i == selected;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => _controller.select(i),
            child: GestureDetector(
              onTap: () => unawaited(_controller.activate(i)),
              child: ColoredBox(
                color: isSelected ? AppColors.selectedRow : AppColors.row,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: ColoredBox(
                          color: AppColors.selectedRow,
                          child: Center(
                            child: Text(
                              item.title.trim().isEmpty
                                  ? '?'
                                  : item.title.trim()[0].toUpperCase(),
                              style: AppTextStyles.placeholderLetter,
                            ),
                          ),
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
                              style: AppTextStyles.rowTitle,
                            ),
                            if ((item.subtitle ?? '').isNotEmpty)
                              Text(
                                item.subtitle!,
                                overflow: TextOverflow.ellipsis,
                                style: AppTextStyles.rowSubtitle,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
