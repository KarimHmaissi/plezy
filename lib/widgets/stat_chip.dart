import 'package:flutter/material.dart';

import '../utils/text_measure_cache.dart';
import 'app_icon.dart';

/// Small labeled pill (optionally with a leading icon): detail-screen stat
/// chips, request-sheet season status labels.
class StatChip extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String label;

  /// Leading artwork for chips whose source has a brand mark (rating badges).
  /// Takes precedence over [icon].
  final Widget? leading;

  /// Overrides the default fill. Needed where the chip sits on a surface that
  /// already uses `surfaceContainerHigh` — the mono theme collapses several
  /// container roles onto one colour, so the default would be invisible.
  final Color? backgroundColor;

  /// The label's size; null keeps the theme's `labelMedium`. The padding and
  /// the icon follow it, so a TV caller can size the pill in its own scale.
  final double? fontSize;

  const StatChip({
    super.key,
    this.icon,
    this.iconColor,
    required this.label,
    this.leading,
    this.backgroundColor,
    this.fontSize,
  });

  static TextStyle? _labelStyle(ThemeData theme, double? fontSize) {
    final base = theme.textTheme.labelMedium;
    return fontSize == null ? base : (base ?? const TextStyle()).copyWith(fontSize: fontSize);
  }

  /// 1 at the default size; [fontSize] over `labelMedium`'s size otherwise.
  static double _ratio(ThemeData theme, double? fontSize) =>
      fontSize == null ? 1 : fontSize / (theme.textTheme.labelMedium?.fontSize ?? 12);

  /// The pill's size for [label] (with an [icon] or not) before it is laid
  /// out, for callers that reserve its room up front.
  static Size sizeFor(BuildContext context, String label, {bool icon = false, double? fontSize}) {
    final theme = Theme.of(context);
    final k = _ratio(theme, fontSize);
    final text = cachedSingleLineTextSize(
      label,
      style: DefaultTextStyle.of(context).style.merge(_labelStyle(theme, fontSize)),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
    );
    final iconSize = 14 * k;
    final contentWidth = text.width + (icon ? iconSize + 4 * k : 0);
    final contentHeight = icon && iconSize > text.height ? iconSize : text.height;
    return Size(contentWidth + 20 * k, contentHeight + 10 * k);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = _ratio(theme, fontSize);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * k, vertical: 5 * k),
      decoration: BoxDecoration(
        color: backgroundColor ?? theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading case final leading?) ...[
            leading,
            SizedBox(width: 4 * k),
          ] else if (icon != null) ...[
            AppIcon(icon!, size: 14 * k, fill: 1, color: iconColor),
            SizedBox(width: 4 * k),
          ],
          Text(label, style: _labelStyle(theme, fontSize)),
        ],
      ),
    );
  }
}
