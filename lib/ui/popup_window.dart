import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:material_ui/material_ui.dart';
import 'package:layer_shell/layer_shell.dart';

import 'app_theme.dart';

/// A reusable layer-shell popup surface anchored to the top-right of the screen.
/// Call [createController] to get a [LayershellWindowController], then add it
/// to your [ViewCollection] with [PopupWindow] as the child.
class PopupWindowConfig {
  const PopupWindowConfig({
    required this.width,
    required this.height,
    required this.namespace,
    this.anchorEdges = const [LayerShellEdge.top, LayerShellEdge.right],
    this.layer = LayerShellLayer.overlay,
    this.keyboardMode = LayerShellKeyboardMode.none,
    this.exclusiveZone = 0,
  });

  final int width;
  final int height;
  final String namespace;
  final List<LayerShellEdge> anchorEdges;
  final LayerShellLayer layer;
  final LayerShellKeyboardMode keyboardMode;
  final int exclusiveZone;
}

LayershellWindowController createPopupController(
  PopupWindowConfig config, [
  ffi.Pointer<ffi.NativeType>? monitor,
]) {
  return LayershellWindowController(
    layer: config.layer,
    anchorEdges: config.anchorEdges,
    keyboardMode: config.keyboardMode,
    width: config.width,
    height: config.height,
    exclusiveZone: config.exclusiveZone,
    monitor: monitor,
    namespace: config.namespace,
  );
}

/// Generic popup widget: a [MouseRegion] that notifies hover state and renders
/// [child] inside a styled container.
class PopupWindow extends StatelessWidget {
  const PopupWindow({
    super.key,
    required this.config,
    required this.child,
    this.onHoverChanged,
  });

  final PopupWindowConfig config;
  final Widget child;
  final ValueChanged<bool>? onHoverChanged;

  @override
  Widget build(BuildContext context) {
    final surface = Material(
      color: AppColors.background,
      child: Container(
        width: config.width.toDouble(),
        height: config.height.toDouble(),
        decoration: BoxDecoration(
          color: AppColors.row,
          border: Border.all(color: AppColors.hint, width: 1),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(12),
        child: child,
      ),
    );
    final onHoverChanged = this.onHoverChanged;
    if (onHoverChanged == null) return surface;
    return MouseRegion(
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: surface,
    );
  }
}

/// A mixin for shell states that manage one or more popup surfaces.
/// Provides hover tracking with a debounce so the popup stays open while
/// the cursor moves between the trigger and the popup itself.
mixin PopupSurfaceMixin<T extends StatefulWidget> on State<T> {
  final Map<String, LayershellWindowController?> _popupControllers = {};
  final Map<String, bool> _hoveringTrigger = {};
  final Map<String, bool> _hoveringPopup = {};
  final Map<String, Timer?> _hideTimers = {};

  /// Click opens a popup; pointer tracking only dismisses it after the pointer
  /// leaves both the trigger and popup.
  void onTriggerTap(String key) {
    _hideTimers[key]?.cancel();
    _hideTimers[key] = null;
    _hoveringTrigger[key] = true;
    _showPopup(key);
  }

  /// Track pointer movement for click-opened popups without opening them.
  void onTriggerPointer(String key, bool hovering) {
    _hoveringTrigger[key] = hovering;
    if (hovering) {
      _hideTimers[key]?.cancel();
      _hideTimers[key] = null;
    } else {
      _scheduleHide(key);
    }
  }

  /// Call when the popup surface itself is hovered/unhovered.
  void onPopupHover(String key, bool hovering) {
    _hoveringPopup[key] = hovering;
    if (hovering) {
      _hideTimers[key]?.cancel();
      _hideTimers[key] = null;
    } else {
      _scheduleHide(key);
    }
  }

  void _scheduleHide(String key) {
    _hideTimers[key]?.cancel();
    _hideTimers[key] = Timer(const Duration(milliseconds: 200), () {
      if (_hoveringTrigger[key] != true && _hoveringPopup[key] != true) {
        _hidePopup(key);
      }
      _hideTimers[key] = null;
    });
  }

  /// Override to create the controller for [key].
  LayershellWindowController createPopupControllerForKey(
    String key,
    ffi.Pointer<ffi.NativeType>? monitor,
  );

  void _showPopup(String key) {
    if (_popupControllers[key] != null) return;
    final monitor = listMonitors().firstOrNull;
    final controller = createPopupControllerForKey(key, monitor?.gdkMonitor);
    _popupControllers[key] = controller;
    setState(() {});
  }

  void _hidePopup(String key) {
    final controller = _popupControllers[key];
    if (controller == null) return;
    controller.destroy();
    _popupControllers[key] = null;
    _hoveringTrigger[key] = false;
    _hoveringPopup[key] = false;
    setState(() {});
  }

  /// Build the [PopupWindow] for [key], or null if not open.
  Widget? buildPopupView(
    String key,
    PopupWindowConfig config,
    Widget child, {
    bool trackHover = true,
  }) {
    final controller = _popupControllers[key];
    if (controller == null) return null;
    return LayerShellWindow(
      controller: controller,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: AppColors.background,
        ),
        home: PopupWindow(
          config: config,
          child: child,
          onHoverChanged:
              trackHover ? (hovering) => onPopupHover(key, hovering) : null,
        ),
      ),
    );
  }

  void disposePopups() {
    for (final timer in _hideTimers.values) {
      timer?.cancel();
    }
    for (final controller in _popupControllers.values) {
      controller?.destroy();
    }
  }
}
