import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_tokens.dart';

/// Bottone circolare "impostazioni" in alto a destra. Da quando il Profilo è
/// uscito dalla bottom nav (sostituito dalla tab Piano), è il modo per
/// raggiungere le impostazioni dalle schermate principali: spinge `/settings`
/// come pagina a sé (con back).
class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.tonal,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/settings'),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.settings_outlined, size: 22, color: t.dim),
        ),
      ),
    );
  }
}
