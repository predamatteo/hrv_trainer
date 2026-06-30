import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/notifications/plan_reminder.dart';
import '../../shared/training_plan/plan_models.dart';
import '../../shared/training_plan/plan_providers.dart';
import '../../shared/ui/ui.dart';

/// Setup del Piano di allenamento. Gating sull'assessment: senza una frequenza
/// di risonanza misurata non si parte (si reindirizza all'assessment). Poi si
/// sceglie lo scopo, l'implementation intention ("quando/dove") e il ritmo
/// settimanale; la scaletta di 4 settimane è mostrata in anteprima.
class PlanSetupScreen extends ConsumerStatefulWidget {
  const PlanSetupScreen({super.key});

  @override
  ConsumerState<PlanSetupScreen> createState() => _PlanSetupScreenState();
}

class _PlanSetupScreenState extends ConsumerState<PlanSetupScreen> {
  PlanGoal _goal = PlanGoal.calm;

  /// null = "Consigliato" (scaletta di default, frequenza variabile 4→5).
  int? _sessionsPerWeek;
  bool _reminderOn = true;
  TimeOfDay _reminderTime = const TimeOfDay(hour: 8, minute: 0);
  final _intention = TextEditingController();
  bool _creating = false;

  static const _intentionChips = [
    'Dopo la sveglia',
    'Dopo pranzo',
    'Dopo il lavoro',
    'Prima di dormire',
  ];

  @override
  void dispose() {
    _intention.dispose();
    super.dispose();
  }

  Future<void> _create(double bpm) async {
    setState(() => _creating = true);
    final intention = _intention.text.trim();
    await ref.read(planControllerProvider).createPlan(
          goal: _goal,
          resonanceBpm: bpm,
          implementationIntention: intention.isEmpty ? null : intention,
          reminderMinuteOfDay:
              _reminderOn ? _reminderTime.hour * 60 + _reminderTime.minute : null,
          sessionsPerWeek: _sessionsPerWeek,
        );
    // Programma subito il promemoria del piano (separato dai promemoria
    // generici): se l'utente ha attivato un orario, parte da oggi.
    await ref.read(planReminderControllerProvider).reconcile();
    if (mounted) context.go('/piano');
  }

  @override
  Widget build(BuildContext context) {
    final gateAsync = ref.watch(assessmentGateProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: gateAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Errore: $e')),
          data: (gate) => gate.canStartPlan
              ? _form(context, gate)
              : _needsAssessment(context),
        ),
      ),
    );
  }

  Widget _needsAssessment(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        const HeaderBar(title: 'Nuovo piano'),
        const SizedBox(height: 24),
        AppCard(
          color: t.accentTonal,
          border: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.graphic_eq, color: t.accent, size: 28),
              const SizedBox(height: 12),
              Text('Serve prima la tua frequenza di risonanza',
                  style: text.titleMedium),
              const SizedBox(height: 6),
              Text(
                'Il piano cuce ogni sessione sul tuo respiro di risonanza. '
                'Fai una breve valutazione e poi torna qui a comporre il piano.',
                style: text.bodyMedium?.copyWith(color: t.dim),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => context.push('/assessment'),
                  icon: const Icon(Icons.graphic_eq, size: 20),
                  label: const Text('Trova la tua risonanza'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _form(BuildContext context, AssessmentGate gate) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final ladder = buildPlanLadder(sessionsPerWeek: _sessionsPerWeek);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        const HeaderBar(title: 'Nuovo piano'),
        const SizedBox(height: 8),

        if (gate.recommendReassess)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Callout(
              icon: Icons.update,
              text:
                  'La tua valutazione ha ${gate.ageDays} giorni: valuta di rifarla '
                  'per un respiro più preciso. Puoi comunque partire.',
            ),
          ),

        // Lo "scopo" del piano.
        const SectionHeader(title: 'Qual è il tuo scopo?'),
        ...PlanGoal.values.map((g) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _GoalCard(
                goal: g,
                selected: g == _goal,
                onTap: () => setState(() => _goal = g),
              ),
            )),

        const SizedBox(height: 14),
        const SectionHeader(title: 'Quando lo farai?'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Aggancia il respiro a un momento che hai già: rende l’abitudine '
                'molto più probabile.',
                style: text.bodySmall?.copyWith(color: t.dim),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in _intentionChips)
                    Pill(
                      tone: _intention.text == c
                          ? PillTone.primary
                          : PillTone.neutral,
                      label: c,
                      onTap: () => setState(() => _intention.text = c),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _intention,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Es. dopo la sveglia, prima del caffè',
                  isDense: true,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),
        const SectionHeader(title: 'Ritmo settimanale'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Quante sessioni a settimana? Puoi sempre saltare un giorno '
                'senza perdere i progressi.',
                style: text.bodySmall?.copyWith(color: t.dim),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  _freqChip(label: 'Consigliato', value: null),
                  _freqChip(label: '3×', value: 3),
                  _freqChip(label: '4×', value: 4),
                  _freqChip(label: '5×', value: 5),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),
        const SectionHeader(title: 'Promemoria del piano'),
        AppCard(
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ricordami la sessione di oggi'),
                subtitle: Text(
                  'Separato dal check-in mattutino.',
                  style: text.bodySmall?.copyWith(color: t.faint),
                ),
                value: _reminderOn,
                onChanged: (v) => setState(() => _reminderOn = v),
              ),
              if (_reminderOn)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.alarm, color: t.dim),
                  title: const Text('Orario'),
                  trailing: Text(
                    _reminderTime.format(context),
                    style: text.titleMedium,
                  ),
                  onTap: () async {
                    final picked = await showTimePicker(
                        context: context, initialTime: _reminderTime);
                    if (picked != null) setState(() => _reminderTime = picked);
                  },
                ),
            ],
          ),
        ),

        const SizedBox(height: 14),
        const SectionHeader(title: 'Le tue 4 settimane'),
        AppCard(
          child: Column(
            children: [
              for (var i = 0; i < ladder.length; i++) ...[
                if (i > 0) Divider(height: 18, color: t.line),
                _LadderRow(week: ladder[i]),
              ],
            ],
          ),
        ),

        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _creating ? null : () => _create(gate.bpm!),
            icon: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow_rounded),
            label: Text(_creating ? 'Avvio…' : 'Avvia il piano'),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'Si chiude con una nuova valutazione per misurare i progressi.',
            style: text.bodySmall?.copyWith(color: t.faint),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _freqChip({required String label, required int? value}) {
    return Pill(
      tone: _sessionsPerWeek == value ? PillTone.primary : PillTone.neutral,
      label: label,
      onTap: () => setState(() => _sessionsPerWeek = value),
    );
  }
}

class _GoalCard extends StatelessWidget {
  final PlanGoal goal;
  final bool selected;
  final VoidCallback onTap;
  const _GoalCard(
      {required this.goal, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return AppCard(
      onTap: onTap,
      color: selected ? t.primaryTonal : t.surface,
      border: selected ? Colors.transparent : t.line,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            color: selected ? t.primary : t.faint,
            size: 22,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(goal.title, style: text.titleSmall),
                const SizedBox(height: 2),
                Text(goal.purpose,
                    style: text.bodySmall?.copyWith(color: t.dim)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LadderRow extends StatelessWidget {
  final PlanWeek week;
  const _LadderRow({required this.week});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: t.tonal, shape: BoxShape.circle),
          child: Text('${week.index}',
              style: text.titleSmall?.copyWith(color: t.primary)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text('Settimana ${week.index}', style: text.bodyLarge),
        ),
        Text('${week.durationMin} min · ${week.targetSessions}×',
            style: text.bodyMedium?.copyWith(color: t.dim)),
      ],
    );
  }
}
