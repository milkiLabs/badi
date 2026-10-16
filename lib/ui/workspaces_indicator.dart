import 'package:material_ui/material_ui.dart';

import '../platform/wm/wm_service.dart';
import '../platform/wm/wm_workspace.dart';
import 'app_theme.dart';

/// Workspace chips for the top bar, placed right after the `Badi` launcher
/// button: one chip per occupied workspace, active one highlighted.
///
/// Backend-agnostic: driven by [WmService] (Sway IPC today, more compositors
/// later). Renders nothing when no window manager is available, so the bar
/// is unchanged on GNOME/X11. Chips are clickable → focus that workspace.
class WorkspacesIndicator extends StatefulWidget {
  const WorkspacesIndicator({super.key});

  @override
  State<WorkspacesIndicator> createState() => _WorkspacesIndicatorState();
}

class _WorkspacesIndicatorState extends State<WorkspacesIndicator> {
  final _service = WmService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChange);
    _service.start();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_onChange);
    _service.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_service.available) return const SizedBox.shrink();
    final list = _service.visibleWorkspaces;
    if (list.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < list.length; i++) ...[
          _WorkspaceChip(
            workspace: list[i],
            onTap: () => _service.focus(list[i]),
          ),
          if (i != list.length - 1) const SizedBox(width: 4),
        ],
      ],
    );
  }
}

class _WorkspaceChip extends StatelessWidget {
  const _WorkspaceChip({required this.workspace, required this.onTap});

  final WmWorkspace workspace;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = workspace.focused;
    final color = workspace.urgent
        ? AppColors.error
        : active
            ? AppColors.title
            : AppColors.subtitle;
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active ? AppColors.selectedRow : null,
            borderRadius: BorderRadius.circular(6),
            border: !active && workspace.visible
                ? Border.all(color: AppColors.hint, width: 1)
                : null,
          ),
          child: Text(
            workspace.displayLabel,
            style: (active ? AppTextStyles.rowTitle : AppTextStyles.rowSubtitle)
                .copyWith(color: color),
          ),
        ),
      ),
    );
  }
}
