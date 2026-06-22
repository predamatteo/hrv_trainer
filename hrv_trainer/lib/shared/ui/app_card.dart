import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Card base del design system: superficie piena + 1px di linea, raggio ampio.
/// Per le card tinte (primary-tonal, good-tonal…) passa [color] e
/// `border: Colors.transparent` per togliere il bordo, come nel mockup.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Superficie. Default: `tokens.surface`.
  final Color? color;

  /// Bordo. Default: `tokens.line`. Passa `Colors.transparent` per ometterlo.
  final Color? border;

  final double radius;
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.color,
    this.border,
    this.radius = 24,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final borderColor = border ?? t.line;
    final content = Padding(padding: padding, child: child);
    return Material(
      color: color ?? t.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: borderColor == Colors.transparent
            ? BorderSide.none
            : BorderSide(color: borderColor, width: 1),
      ),
      child: onTap == null
          ? content
          : InkWell(onTap: onTap, child: content),
    );
  }
}
