import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../shared/training_plan/post_session_report.dart';
import '../../../shared/ui/ui.dart';

/// Mostra lo step di report soggettivo a fine sessione del piano. Ritorna il
/// report compilato, oppure null se l'utente salta (il report non deve mai
/// essere un ostacolo). [preTension] è la tensione catturata prima della
/// sessione, usata per calcolare il Δ calma.
Future<PostSessionReport?> showPostSessionReportSheet(
  BuildContext context, {
  int? preTension,
}) {
  return showModalBottomSheet<PostSessionReport>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ReportSheet(preTension: preTension),
  );
}

/// Cattura la tensione PRIMA della sessione (1 tap). Ritorna 0–10, o null se
/// l'utente salta. Serve a calcolare il Δ calma a fine sessione (cattura in
/// tempo reale, non a memoria — più valida).
Future<int?> showPreTensionSheet(BuildContext context) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _PreTensionSheet(),
  );
}

class _PreTensionSheet extends StatefulWidget {
  const _PreTensionSheet();
  @override
  State<_PreTensionSheet> createState() => _PreTensionSheetState();
}

class _PreTensionSheetState extends State<_PreTensionSheet> {
  int _tension = 5;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Prima di iniziare', style: text.titleLarge),
          const SizedBox(height: 4),
          Text('Quanto sei teso o agitato in questo momento?',
              style: text.bodyMedium?.copyWith(color: t.dim)),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Per niente', style: text.labelSmall?.copyWith(color: t.faint)),
              const Spacer(),
              Text('$_tension',
                  style: text.titleMedium?.copyWith(color: t.primary)),
              const Spacer(),
              Text('Molto', style: text.labelSmall?.copyWith(color: t.faint)),
            ],
          ),
          Slider(
            min: 0,
            max: 10,
            divisions: 10,
            value: _tension.toDouble(),
            label: '$_tension',
            onChanged: (v) => setState(() => _tension = v.round()),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Salta'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, _tension),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('Inizia'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Scala VAS della calma a fine sessione (singolo item, validato). Cattura ~3s.
class _CalmScale extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _CalmScale({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Agitato', style: text.labelSmall?.copyWith(color: t.faint)),
            const Spacer(),
            Text('$value', style: text.titleMedium?.copyWith(color: t.primary)),
            const Spacer(),
            Text('Calmo', style: text.labelSmall?.copyWith(color: t.faint)),
          ],
        ),
        Slider(
          min: 0,
          max: 10,
          divisions: 10,
          value: value.toDouble(),
          label: '$value',
          onChanged: (v) => onChanged(v.round()),
        ),
      ],
    );
  }
}

class _ReportSheet extends StatefulWidget {
  final int? preTension;
  const _ReportSheet({this.preTension});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  int _calm = 5;
  int? _mood;
  final Set<BodySensation> _sensations = {};
  final _note = TextEditingController();

  static const _moodEmoji = ['😣', '🙁', '😐', '🙂', '😄'];

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  PostSessionReport _build() => PostSessionReport(
        tensionPre: widget.preTension,
        calmPost: _calm,
        mood: _mood,
        sensations: _sensations.toList(),
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 16 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Com’è andata?', style: text.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Un attimo per notare come ti senti. Allena la consapevolezza — '
              'e resta tracciato nel tuo storico.',
              style: text.bodySmall?.copyWith(color: t.dim),
            ),
            const SizedBox(height: 18),

            Text('Quanto ti senti calmo ora?', style: text.titleSmall),
            const SizedBox(height: 4),
            _CalmScale(value: _calm, onChanged: (v) => setState(() => _calm = v)),
            const SizedBox(height: 16),

            Text('Il tuo umore', style: text.titleSmall),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < _moodEmoji.length; i++)
                  _MoodButton(
                    emoji: _moodEmoji[i],
                    selected: _mood == i + 1,
                    onTap: () => setState(() => _mood = i + 1),
                  ),
              ],
            ),
            const SizedBox(height: 18),

            Text('Cosa noti nel corpo?', style: text.titleSmall),
            const SizedBox(height: 4),
            Text('Facoltativo · scegline quante vuoi',
                style: text.labelSmall?.copyWith(color: t.faint)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in BodySensation.values)
                  Pill(
                    tone: _sensations.contains(s)
                        ? (s.isPositive ? PillTone.good : PillTone.warn)
                        : PillTone.neutral,
                    label: s.label,
                    onTap: () => setState(() {
                      _sensations.contains(s)
                          ? _sensations.remove(s)
                          : _sensations.add(s);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _note,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Una nota (facoltativa)',
                hintText: 'Es. respiro più profondo del solito',
              ),
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Salta'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, _build()),
                    child: const Text('Salva'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MoodButton extends StatelessWidget {
  final String emoji;
  final bool selected;
  final VoidCallback onTap;
  const _MoodButton(
      {required this.emoji, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: selected ? t.primaryTonal : t.tonal,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 52,
          height: 52,
          child: Center(child: Text(emoji, style: const TextStyle(fontSize: 24))),
        ),
      ),
    );
  }
}
