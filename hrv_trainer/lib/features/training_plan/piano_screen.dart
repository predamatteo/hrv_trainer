import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/notifications/plan_reminder.dart';
import '../../shared/training_plan/plan_models.dart';
import '../../shared/training_plan/plan_providers.dart';
import '../../shared/ui/ui.dart';

/// Tab "Piano": il programma di allenamento. Senza un piano attivo mostra
/// l'invito a comporne uno; con un piano attivo mostra scopo, progresso della
/// settimana, traguardo cumulativo e la sessione consigliata di oggi.
class PianoScreen extends ConsumerWidget {
  const PianoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final planAsync = ref.watch(activePlanProvider);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(activePlanProvider);
            ref.invalidate(planProgressProvider);
            await ref.read(activePlanProvider.future);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              Row(
                children: [
                  Expanded(child: Text('Piano', style: text.headlineSmall)),
                  const SettingsButton(),
                ],
              ),
              const SizedBox(height: 12),
              planAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.only(top: 80),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => AppCard(child: Text('Errore: $e')),
                data: (plan) => plan == null
                    ? const _EmptyPlan()
                    : _ActivePlan(plan: plan),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyPlan extends StatelessWidget {
  const _EmptyPlan();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          color: t.primaryTonal,
          border: Colors.transparent,
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.calendar_month_rounded, color: t.primary, size: 30),
              const SizedBox(height: 14),
              Text('Allena la calma, con un percorso', style: text.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Un piano di 4 settimane che parte in piccolo e cresce con te. '
                'Niente 5×20 minuti dal primo giorno: poche sessioni brevi, '
                'che diventano abitudine. Si chiude misurando i tuoi progressi.',
                style: text.bodyMedium?.copyWith(color: t.dim),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => context.push('/piano/setup'),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Inizia un piano'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const _WhyPlanList(),
      ],
    );
  }
}

/// Tre motivi (fondati sull'evidenza) per cui un piano aiuta — calmi, non
/// venduti come slogan.
class _WhyPlanList extends StatelessWidget {
  const _WhyPlanList();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    const items = [
      (
        Icons.trending_up_rounded,
        'Cresci per gradi',
        'Iniziare in piccolo costruisce l’abitudine meglio di partire in grande.'
      ),
      (
        Icons.favorite_outline_rounded,
        'Uno scopo, non un numero',
        'L’obiettivo è la costanza: i segnali HRV restano un feedback, non un voto.'
      ),
      (
        Icons.event_available_outlined,
        'Tollerante',
        'Salti un giorno? Il livello tiene. Riprendi domani, senza sensi di colpa.'
      ),
    ];
    return Column(
      children: [
        for (final (icon, title, body) in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(icon, color: t.accent, size: 22),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: text.titleSmall),
                        const SizedBox(height: 2),
                        Text(body,
                            style: text.bodySmall?.copyWith(color: t.dim)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ActivePlan extends ConsumerWidget {
  final TrainingPlan plan;
  const _ActivePlan({required this.plan});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final progressAsync = ref.watch(planProgressProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Scopo del piano.
        AppCard(
          color: t.primaryTonal,
          border: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Pill(tone: PillTone.primary, label: plan.goal.shortLabel),
              const SizedBox(height: 12),
              Text(plan.goal.title, style: text.titleLarge),
              const SizedBox(height: 6),
              Text(plan.goal.purpose,
                  style: text.bodyMedium?.copyWith(color: t.dim)),
              if (plan.implementationIntention != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.schedule, size: 16, color: t.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(plan.implementationIntention!,
                          style: text.bodySmall?.copyWith(color: t.dim)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        progressAsync.when(
          loading: () => const AppCard(
            child: SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
          ),
          error: (e, _) => AppCard(child: Text('Errore: $e')),
          data: (progress) => progress == null
              ? const SizedBox.shrink()
              : _ProgressBody(plan: plan, progress: progress),
        ),
        const SizedBox(height: 24),
        Center(
          child: TextButton.icon(
            onPressed: () => _confirmAbandon(context, ref),
            icon: Icon(Icons.close_rounded, size: 18, color: t.faint),
            label: Text('Abbandona il piano',
                style: text.bodyMedium?.copyWith(color: t.faint)),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmAbandon(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Abbandonare il piano?'),
        content: const Text(
            'I progressi e lo storico delle sessioni restano. Potrai sempre '
            'iniziarne uno nuovo.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Abbandona')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(planControllerProvider).abandonActivePlan();
    await ref.read(planReminderControllerProvider).reconcile();
  }
}

class _ProgressBody extends StatelessWidget {
  final TrainingPlan plan;
  final PlanProgress progress;
  const _ProgressBody({required this.plan, required this.progress});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;

    if (progress.reachedGraduation) {
      return const _GraduationCard();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Settimana corrente + aderenza della finestra.
        AppCard(
          child: Row(
            children: [
              ReadinessRing(
                progress: progress.windowAdherence,
                color: t.primary,
                trackColor: t.line,
                size: 84,
                strokeWidth: 7,
                center: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${progress.completedThisWindow}/${progress.targetThisWindow}',
                        style: text.titleMedium?.copyWith(height: 1)),
                    Text('settimana',
                        style: text.labelSmall?.copyWith(color: t.faint)),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Settimana ${progress.currentLevel} di ${plan.durationWeeks}',
                        style: text.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '${progress.currentWeek.durationMin} minuti a sessione, '
                      'al tuo respiro di risonanza.',
                      style: text.bodySmall?.copyWith(color: t.dim),
                    ),
                    if (progress.readyToAdvance && !progress.windowComplete) ...[
                      const SizedBox(height: 8),
                      Pill(
                          tone: PillTone.good,
                          icon: Icons.check_circle_outline,
                          label: 'Pronto per la prossima settimana'),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Sessione di oggi.
        _TodayCta(plan: plan, progress: progress),
        const SizedBox(height: 14),

        // Vista a calendario delle settimane del piano.
        _PlanCalendar(
          plan: plan,
          rows: progress.windowIndex + 1 > plan.durationWeeks
              ? progress.windowIndex + 1
              : plan.durationWeeks,
        ),
        const SizedBox(height: 14),

        // Traguardo cumulativo (non si azzera mai).
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text('Progresso totale', style: text.titleSmall)),
                  Text('${progress.totalCompleted}/${progress.totalTarget}',
                      style: text.titleSmall?.copyWith(color: t.primary)),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress.overallProgress,
                  minHeight: 8,
                  backgroundColor: t.tonal2,
                  color: t.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text('Sessioni del piano completate, dall’inizio.',
                  style: text.bodySmall?.copyWith(color: t.faint)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Vista a calendario del piano: una riga per settimana (finestre di 7 giorni a
/// partire dall'inizio del piano, coerenti col motore di progressione), un
/// pallino pieno nei giorni con una sessione completata. Niente allineamento
/// Lun–Dom: le settimane scorrono dall'inizio del piano, com'è nell'aderenza.
class _PlanCalendar extends ConsumerWidget {
  final TrainingPlan plan;
  final int rows;
  const _PlanCalendar({required this.plan, required this.rows});

  static int _key(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final times = ref.watch(planSessionTimesProvider).valueOrNull ?? const [];
    final done = {for (final tm in times) _key(tm)};
    final todayDate = DateUtils.dateOnly(DateTime.now());
    final todayKey = _key(todayDate);
    final start = DateUtils.dateOnly(plan.startedAt);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Calendario', style: text.titleSmall)),
              _LegendDot(color: t.primary, label: 'fatto'),
            ],
          ),
          const SizedBox(height: 12),
          for (var w = 0; w < rows; w++) ...[
            if (w > 0) const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Text('S${w + 1}',
                      style: text.labelMedium?.copyWith(color: t.faint)),
                ),
                for (var d = 0; d < 7; d++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _DayCell(
                        date: DateUtils.addDaysToDate(start, w * 7 + d),
                        done: done,
                        todayKey: todayKey,
                        todayDate: todayDate,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  final DateTime date;
  final Set<int> done;
  final int todayKey;
  final DateTime todayDate;
  const _DayCell({
    required this.date,
    required this.done,
    required this.todayKey,
    required this.todayDate,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final k = _PlanCalendar._key(date);
    final isDone = done.contains(k);
    final isToday = k == todayKey;
    final isFuture = date.isAfter(todayDate);

    final Color bg;
    final Color fg;
    if (isDone) {
      bg = t.primary;
      fg = t.onPrimary;
    } else if (isFuture) {
      bg = Colors.transparent;
      fg = t.faint;
    } else {
      bg = t.tonal;
      fg = t.dim;
    }

    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(9),
          border: isToday
              ? Border.all(color: t.primary, width: 2)
              : (isFuture ? Border.all(color: t.line) : null),
        ),
        alignment: Alignment.center,
        child: Text('${date.day}',
            style: text.labelMedium?.copyWith(
                color: fg, fontWeight: isToday ? FontWeight.w700 : null)),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(label, style: text.labelSmall?.copyWith(color: t.faint)),
      ],
    );
  }
}

class _TodayCta extends StatelessWidget {
  final TrainingPlan plan;
  final PlanProgress progress;
  const _TodayCta({required this.plan, required this.progress});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;

    if (!progress.recommendToday) {
      final msg = progress.completedToday > 0
          ? 'Fatto per oggi. Bel lavoro.'
          : 'Settimana completata: questo è un extra, senza pressioni.';
      return AppCard(
        color: t.goodTonal,
        border: Colors.transparent,
        child: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: t.good, size: 24),
            const SizedBox(width: 14),
            Expanded(child: Text(msg, style: text.bodyMedium)),
          ],
        ),
      );
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('La tua sessione di oggi', style: text.titleMedium),
          const SizedBox(height: 4),
          Text('Circa ${progress.recommendedDurationMin} minuti · segui il cerchio.',
              style: text.bodySmall?.copyWith(color: t.dim)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => context.push(
                  planTrainingLocation(plan, progress.recommendedDurationMin)),
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text('Inizia'),
            ),
          ),
        ],
      ),
    );
  }
}

class _GraduationCard extends StatelessWidget {
  const _GraduationCard();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return AppCard(
      color: t.accentTonal,
      border: Colors.transparent,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.workspace_premium_rounded, color: t.accent, size: 30),
          const SizedBox(height: 12),
          Text('Hai completato il piano!', style: text.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Quattro settimane di respiro guidato. Rifai la valutazione di '
            'risonanza per vedere — nero su bianco — quanto è cambiato.',
            style: text.bodyMedium?.copyWith(color: t.dim),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => context.push('/assessment'),
              icon: const Icon(Icons.graphic_eq, size: 20),
              label: const Text('Misura i progressi'),
            ),
          ),
        ],
      ),
    );
  }
}
