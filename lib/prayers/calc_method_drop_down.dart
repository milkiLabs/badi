import 'package:badi/prayers/calculation_method_info.dart';
import 'package:material_ui/material_ui.dart';

/// Controlled calculation-method picker: [value] + [onChanged].
/// Expands inline instead of opening an overlay menu.
class CalcMethodDropDown extends StatefulWidget {
  const CalcMethodDropDown({
    required this.value,
    required this.onChanged,
    super.key,
  });
  final String value;
  final void Function(String) onChanged;

  @override
  State<CalcMethodDropDown> createState() => _CalcMethodDropDownState();
}

class _CalcMethodDropDownState extends State<CalcMethodDropDown> {
  bool _expanded = false;

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      // Bring the opened list into view once the size animation is done.
      Future.delayed(const Duration(milliseconds: 220), () {
        if (!mounted) return;
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 180),
          alignment: 0.1,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          ),
          onPressed: _toggle,
          child: Row(
            children: [
              const Icon(Icons.calculate),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  CalculationMethodInfo.getArabicName(widget.value),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.colorScheme.onSurface),
                ),
              ),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            ],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: _expanded
              ? Container(
                  margin: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                      children: [
                        for (final method in CalculationMethodInfo.methods)
                          ListTile(
                            dense: true,
                            title: Text(
                              CalculationMethodInfo.getArabicName(method.key),
                            ),
                            trailing: method.key == widget.value
                                ? const Icon(Icons.check)
                                : null,
                            onTap: () {
                              setState(() => _expanded = false);
                              widget.onChanged(method.key);
                            },
                          ),
                      ],
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
