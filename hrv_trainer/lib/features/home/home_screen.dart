import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/connect_iq/watch_readiness.dart';
import '../../shared/hrv/hrv_metrics.dart';
import '../../shared/hrv/readiness.dart';
import '../../shared/profile/user_profile_provider.dart';
import '../../shared/ui/ui.dart';
import '../readiness/state/readiness_providers.dart';
import 'state/readiness_provider.dart';

/// Home — launchpad: saluto, stato orologio, card di prontezza con anello HRV
/// e griglia delle pratiche. Il dettaglio (messaggio, RMSSD, CV, grafico) vive
/// in `/readiness`; la cronaca cronica in `/hrv`.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final name = ref.watch(userNameProvider);
    final watch = ref.watch(watchReadinessProvider);
    final readinessAsync = ref.watch(readinessProvider);
    final doneToday = ref.watch(morningCheckInDoneTodayProvider).valueOrNull ?? false;

    final now = DateTime.now();
    final dateStr = _capitalize(DateFormat('EEEE d MMMM', 'it_IT').format(now));

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(readinessProvider);
            ref.invalidate(morningCheckInDoneTodayProvider);
            ref.invalidate(morningReadingsProvider);
            await ref.read(readinessProvider.future);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
            children: [
              // Saluto + impostazioni.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(dateStr, style: text.bodyMedium?.copyWith(color: t.dim)),
                        const SizedBox(height: 2),
                        Text(
                          name == null ? _greeting(now) : '${_greeting(now)}, $name',
                          style: text.headlineSmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _CircleIconButton(
                    icon: Icons.settings_outlined,
                    onTap: () => context.go('/settings'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _GarminPill(watch: watch),
              const SizedBox(height: 16),
              readinessAsync.when(
                loading: () => const _HeroSkeleton(),
                error: (e, _) => AppCard(
                  child: Text('Prontezza non disponibile: $e', style: text.bodyMedium),
                ),
                data: (r) => _ReadinessHero(readiness: r, doneToday: doneToday),
              ),
              const SizedBox(height: 12),
              const _HrvTrendEntry(),
              const SizedBox(height: 22),
              const SectionHeader(title: 'Pratiche'),
              const _PracticeGrid(),
            ],
          ),
        ),
      ),
    );
  }

  static String _greeting(DateTime now) {
    final h = now.hour;
    if (h < 12) return 'Buongiorno';
    if (h < 18) return 'Buon pomeriggio';
    return 'Buonasera';
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

String _comma(double v, int digits) => v.toStringAsFixed(digits).replaceAll('.', ',');

class _GarminPill extends StatelessWidget {
  final WatchReadiness watch;
  const _GarminPill({required this.watch});

  @override
  Widget build(BuildContext context) {
    final (tone, icon, label) = switch (watch) {
      WatchReadiness.ready => (PillTone.primary, Icons.watch, 'Garmin Instinct · connesso'),
      WatchReadiness.connecting => (PillTone.neutral, Icons.watch, 'Garmin · connessione…'),
      WatchReadiness.bluetoothOff => (PillTone.warn, Icons.bluetooth_disabled, 'Bluetooth spento'),
      _ => (PillTone.neutral, Icons.watch_off, 'Garmin · non connesso'),
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Pill(tone: tone, icon: icon, label: label),
    );
  }
}

class _ReadinessHero extends StatelessWidget {
  final Readiness readiness;
  final bool doneToday;
  const _ReadinessHero({required this.readiness, required this.doneToday});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final r = readiness;

    // Semaforo demotato (anti-ansia): un piccolo Dot colore-banda su pillola
    // neutra come unico segnale, niente pillola colorata allarmante. Lo stato
    // calmo vive nell'headline (r.headline), il colore resta sull'anello HRV.
    final color = switch (r.band) {
      ReadinessBand.green => t.good,
      ReadinessBand.yellow => t.warn,
      ReadinessBand.red => t.alert,
      ReadinessBand.unknown => t.primary,
    };

    final isUnknown = r.band == ReadinessBand.unknown;
    final score = HrvMetrics.scoreFromRmssd(r.todayRmssd);

    final desc = switch (r.band) {
      ReadinessBand.green => 'Sistema parasimpatico ben recuperato. Buona giornata per allenarti.',
      ReadinessBand.yellow => r.vagalSaturation
          ? 'Probabile saturazione vagale: una sessione tranquilla, senza forzare.'
          : 'Recupero sotto la tua norma: oggi meglio un carico leggero.',
      ReadinessBand.red => 'Sistema sotto stress: dai priorità a riposo e respiro lento.',
      ReadinessBand.unknown => r.message,
    };

    final cta = doneToday
        ? const _CtaSpec('Avvia la sessione di risonanza', Icons.monitor_heart, '/training')
        : const _CtaSpec('Inizia il check-in del mattino', Icons.wb_twilight, '/readiness/checkin');

    return AppCard(
      onTap: () => context.push('/readiness'),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Pill(tone: PillTone.neutral, leading: Dot(color), label: 'Prontezza di oggi'),
                    const SizedBox(height: 14),
                    Text(r.headline, style: text.titleLarge),
                    const SizedBox(height: 6),
                    Text(desc, style: text.bodyMedium?.copyWith(color: t.dim)),
                  ],
                ),
              ),
              if (!isUnknown) ...[
                const SizedBox(width: 14),
                ReadinessRing(
                  progress: score / 100,
                  color: color,
                  trackColor: t.line,
                  size: 88,
                  strokeWidth: 7,
                  center: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${score.round()}',
                          style: text.headlineSmall?.copyWith(height: 1)),
                      const SizedBox(height: 2),
                      Text('HRV',
                          style: text.labelSmall?.copyWith(color: t.faint, letterSpacing: 1)),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (!isUnknown && (r.zScore != null || r.cvPct != null)) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (r.zScore != null)
                  Pill(
                    child: RichText(
                      text: TextSpan(
                        style: text.labelLarge?.copyWith(color: t.dim),
                        children: [
                          TextSpan(
                            text: '${r.zScore! >= 0 ? '+' : ''}${_comma(r.zScore!, 1)} SD ',
                            style: TextStyle(color: t.text, fontWeight: FontWeight.w700),
                          ),
                          const TextSpan(text: 'rispetto a te'),
                        ],
                      ),
                    ),
                  ),
                if (r.cvPct != null)
                  Pill(
                    child: RichText(
                      text: TextSpan(
                        style: text.labelLarge?.copyWith(color: t.dim),
                        children: [
                          const TextSpan(text: 'Serie '),
                          TextSpan(
                            text: r.cvLabel,
                            style: TextStyle(color: t.text, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => context.push(cta.route),
              icon: Icon(cta.icon, size: 20),
              label: Text(cta.label),
            ),
          ),
        ],
      ),
    );
  }
}

class _CtaSpec {
  final String label;
  final IconData icon;
  final String route;
  const _CtaSpec(this.label, this.icon, this.route);
}

/// Ingresso alla cronaca cronica `/hrv` ("specchio settimanale"): la storia
/// lenta dei progressi, distinta dalla prontezza di oggi (`_ReadinessHero` →
/// `/readiness`). Usa push come il gemello, così il back torna in Home.
class _HrvTrendEntry extends StatelessWidget {
  const _HrvTrendEntry();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return AppCard(
      onTap: () => context.push('/hrv'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: t.primaryTonal, shape: BoxShape.circle),
            child: Icon(Icons.insights, size: 22, color: t.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Andamento HRV', style: text.titleSmall),
                const SizedBox(height: 2),
                Text('Specchio settimanale',
                    style: text.bodySmall?.copyWith(color: t.dim)),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: t.faint),
        ],
      ),
    );
  }
}

class _PracticeGrid extends StatelessWidget {
  const _PracticeGrid();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: PracticeCard(
                compact: true,
                icon: Icons.self_improvement,
                title: 'Respiro libero',
                subtitle: 'Pacer a ~6/min',
                tone: PillTone.accent,
                onTap: () => context.push('/pacer'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PracticeCard(
                compact: true,
                tinted: true,
                icon: Icons.monitor_heart,
                title: 'Biofeedback',
                subtitle: 'Sessione con orologio',
                tone: PillTone.primary,
                onTap: () => context.push('/training'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: PracticeCard(
                compact: true,
                icon: Icons.wb_twilight,
                title: 'Check-in',
                subtitle: 'Lettura mattutina',
                tone: PillTone.accent,
                onTap: () => context.push('/readiness/checkin'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PracticeCard(
                compact: true,
                icon: Icons.graphic_eq,
                title: 'Assessment',
                subtitle: 'Trova la risonanza',
                tone: PillTone.accent,
                onTap: () => context.push('/assessment'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.tonal,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 22, color: t.dim)),
      ),
    );
  }
}

class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();
  @override
  Widget build(BuildContext context) => const AppCard(
        child: SizedBox(height: 150, child: Center(child: CircularProgressIndicator())),
      );
}
