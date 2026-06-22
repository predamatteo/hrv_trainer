import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Intestazione di sezione ("Pratiche", "Metriche"…): etichetta attenuata in
/// maiuscoletto morbido + azione opzionale a destra.
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.only(left: 2, right: 2, bottom: 10),
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: t.dim,
                    letterSpacing: 0.2,
                  ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
