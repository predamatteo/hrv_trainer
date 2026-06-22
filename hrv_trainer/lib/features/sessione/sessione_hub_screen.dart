import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/ui/ui.dart';

/// Hub della tab "Sessione": punto di partenza per le pratiche. Il mockup mostra
/// queste voci anche nella griglia "Pratiche" della Home; qui hanno descrizioni
/// più ampie. Ogni voce apre un flusso immersivo (route sul navigator root).
class SessioneHubScreen extends StatelessWidget {
  const SessioneHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 4),
              child: Text('Sessione', style: text.headlineSmall),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 18),
              child: Text(
                'Scegli una pratica per iniziare',
                style: text.bodyMedium?.copyWith(color: t.dim),
              ),
            ),
            _PracticeCard(
              icon: Icons.monitor_heart,
              tone: PillTone.primary,
              title: 'Biofeedback',
              subtitle: 'Sessione guidata con l’orologio: respiro, RSA e coerenza dal vivo',
              onTap: () => context.push('/training'),
            ),
            const SizedBox(height: 12),
            _PracticeCard(
              icon: Icons.self_improvement,
              tone: PillTone.accent,
              title: 'Respiro libero',
              subtitle: 'Pacer a ~6 respiri/min, senza registrazione',
              onTap: () => context.push('/pacer'),
            ),
            const SizedBox(height: 12),
            _PracticeCard(
              icon: Icons.wb_twilight,
              tone: PillTone.accent,
              title: 'Check-in mattutino',
              subtitle: 'Lettura di prontezza riferita alla tua norma',
              onTap: () => context.push('/readiness/checkin'),
            ),
            const SizedBox(height: 12),
            _PracticeCard(
              icon: Icons.graphic_eq,
              tone: PillTone.accent,
              title: 'Assessment',
              subtitle: 'Scansione dei ritmi per trovare la tua frequenza di risonanza',
              onTap: () => context.push('/assessment'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PracticeCard extends StatelessWidget {
  final IconData icon;
  final PillTone tone;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PracticeCard({
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final c = Pill.colorsFor(tone, t);
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(16)),
            child: Icon(icon, color: c.fg, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium),
                const SizedBox(height: 3),
                Text(subtitle, style: text.bodySmall?.copyWith(color: t.dim)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right, color: t.faint),
        ],
      ),
    );
  }
}
