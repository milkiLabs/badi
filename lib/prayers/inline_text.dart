import 'package:material_ui/material_ui.dart';

/// Single-line shrink-to-fit text.
///
/// Replacement for `text_responsive`'s `InlineTextWidget`, which measured
/// with `maxLines: 1` and shrank the font to fit. [FittedBox] with
/// [BoxFit.scaleDown] does the same thing declaratively: it only ever
/// scales *down*, never up.
///
/// Intended for short single-line labels (prayer names, times, button
/// labels, dates) — not for wrapping paragraph text.
class InlineTextWidget extends StatelessWidget {
  const InlineTextWidget(
    this.text, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.semanticsLabel,
    this.selectionColor,
  });

  final String text;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final String? semanticsLabel;
  final Color? selectionColor;

  /// Maps [TextAlign] to the [FittedBox] alignment. Start/end stay
  /// directional ([AlignmentDirectional]) so `TextAlign.start` hugs the
  /// leading edge in both locales — a physical `centerLeft` here pushed
  /// RTL names away from their icons.
  AlignmentGeometry _alignmentFor(TextAlign? align) {
    switch (align) {
      case TextAlign.right:
        return Alignment.centerRight;
      case TextAlign.left:
        return Alignment.centerLeft;
      case TextAlign.start:
        return AlignmentDirectional.centerStart;
      case TextAlign.end:
        return AlignmentDirectional.centerEnd;
      case TextAlign.center:
      case TextAlign.justify:
      case null:
        return Alignment.center;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: _alignmentFor(textAlign),
      child: Text(
        text,
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        locale: locale,
        softWrap: softWrap ?? false,
        overflow: overflow,
        textScaler: textScaler,
        semanticsLabel: semanticsLabel,
        selectionColor: selectionColor,
        maxLines: 1,
      ),
    );
  }
}
