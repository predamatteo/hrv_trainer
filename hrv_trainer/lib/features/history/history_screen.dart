import 'dart:convert';
import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../shared/connect_iq/hr_source_provider.dart';
import '../../shared/hrv/session_models.dart';
import '../../shared/storage/session_repository.dart';
import '../home/state/readiness_provider.dart';
import 'widgets/hrv_histogram.dart';

/// Finestra temporale del filtro storico.
///
/// `days == null` significa "tutto lo storico" (nessun filtro temporale).
/// I preset comuni sono esposti come costanti statiche; valori arbitrari
/// (1-3650) sono ammessi tramite il dialog "Personalizza...".
///
/// Cap a 3650 (~10 anni): tetto sano per evitare overflow in `Duration` e
/// per il fatto che nessuna sessione HRV Trainer reale è più vecchia di
/// così — l'app è del 2026.
class HistoryFilter {
  final int? days;
  final SessionTag? tag;
  const HistoryFilter({this.days = 30, this.tag});

  static const presetDays = [7, 30, 60];
  static const maxCustomDays = 3650;

  HistoryFilter copyWith({
    Object? days = _sentinel,
    SessionTag? tag,
    bool clearTag = false,
  }) =>
      HistoryFilter(
        // _sentinel permette di distinguere "non passato" da "passato esplicitamente null"
        // (= filtro "Tutto"), senza dover esporre un flag extra.
        days: identical(days, _sentinel) ? this.days : days as int?,
        tag: clearTag ? null : (tag ?? this.tag),
      );

  String get label {
    if (days == null) return 'Tutto';
    return '$days gg';
  }

  static const Object _sentinel = Object();
}

final historyFilterProvider =
    StateProvider<HistoryFilter>((ref) => const HistoryFilter());

final sessionsListProvider =
    FutureProvider.autoDispose<List<Session>>((ref) async {
  final f = ref.watch(historyFilterProvider);
  // days == null → mostra tutto, niente filtro temporale.
  final since = f.days == null
      ? null
      : DateTime.now().subtract(Duration(days: f.days!));
  return ref.watch(sessionRepositoryProvider).listSessions(
        tag: f.tag,
        since: since,
        // Quando il filtro è "Tutto" alziamo il limit così l'utente vede
        // davvero tutto lo storico — il limite fisso da 200 era una guard
        // anti-OOM ereditata da quando il default era 30 gg, ma in modalità
        // "Tutto" l'utente si aspetta zero troncamento.
        limit: f.days == null ? 100000 : 200,
      );
});

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(historyFilterProvider);
    final sessions = ref.watch(sessionsListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Storico & trend'),
        actions: const [
          _SyncWatchAction(),
          _BackupMenu(),
        ],
      ),
      body: Column(
        children: [
          _FiltersBar(filter: filter, ref: ref),
          const Divider(height: 1),
          Expanded(
            child: sessions.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Errore: $e')),
              data: (list) => list.isEmpty
                  ? const _EmptyState()
                  : _HistoryBody(sessions: list),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottone di recovery per sessioni avviate dal watch che non sono mai
/// arrivate al phone (es. app phone killata al momento della trasmissione
/// del SESSION_SUMMARY originale → Garmin Connect Mobile non bufferizza
/// se nessun listener era registrato, e il summary resta orfano nel
/// PendingStore del watch).
///
/// Premendolo: il bridge fa `openApplication` (può scatenare il dialog
/// "Avviare HRV Trainer?" sul Garmin) + sendMessage SYNC_REQUEST. L'app
/// sul watch all'avvio drena il PendingStore ritrasmettendo i summary
/// orfani al phone, che li persiste e manda l'ACK.
class _SyncWatchAction extends ConsumerStatefulWidget {
  const _SyncWatchAction();

  @override
  ConsumerState<_SyncWatchAction> createState() => _SyncWatchActionState();
}

class _SyncWatchActionState extends ConsumerState<_SyncWatchAction> {
  bool _busy = false;

  Future<void> _onPressed() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(heartRateSourceProvider).requestSync(force: true);
      messenger.showSnackBar(const SnackBar(
        duration: Duration(seconds: 4),
        content: Text(
          'Sincronizzazione richiesta. '
          'Se sull\'orologio appare "Avviare HRV Trainer?" conferma per recuperare le sessioni.',
        ),
      ));
    } finally {
      // setState solo se il widget è ancora montato: l'utente potrebbe
      // aver cambiato schermata mentre il channel era pending.
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Sincronizza orologio',
      icon: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync),
      onPressed: _busy ? null : _onPressed,
    );
  }
}

/// Menu di backup manuale: export → JSON via share sheet, import → JSON
/// scelto dal file picker. Garantisce che lo storico sia recuperabile
/// indipendentemente da Auto Backup di Google: l'utente possiede il file.
///
/// L'incidente del 2026-05-10 (DB cancellato da `flutter install` mal
/// utilizzato + Auto Backup non utile per signature mismatch) ha mostrato
/// che fidarsi solo del backup automatico è fragile. Questo è il piano B.
class _BackupMenu extends ConsumerStatefulWidget {
  const _BackupMenu();

  @override
  ConsumerState<_BackupMenu> createState() => _BackupMenuState();
}

class _BackupMenuState extends ConsumerState<_BackupMenu> {
  bool _busy = false;

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    // Cache prima degli await: dopo, accedere a Theme.of(context) richiede
    // un mounted check perché il widget potrebbe essere stato smontato.
    final errorColor = Theme.of(context).colorScheme.error;
    try {
      final repo = ref.read(sessionRepositoryProvider);
      final data = await repo.exportAll();
      final sessCount = (data['sessions'] as List).length;
      final assCount = (data['assessments'] as List).length;

      // Pretty-print JSON: il file potrebbe essere ispezionato a mano
      // o diffato fra backup; formattazione leggibile vale la dimensione.
      const encoder = JsonEncoder.withIndent('  ');
      final jsonStr = encoder.convert(data);

      // File temporaneo con nome parlante: data + ora locali in formato
      // stabile per ordinamento alfabetico, niente caratteri problematici
      // su Windows/Mac/Linux quando l'utente lo salva su Drive o email.
      final stamp = DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now());
      final tmpDir = await getTemporaryDirectory();
      final file = File('${tmpDir.path}/hrv_trainer_backup_$stamp.json');
      await file.writeAsString(jsonStr);

      // Usiamo Share.shareXFiles così l'utente sceglie la destinazione
      // (Drive / Gmail / Files / WhatsApp). Niente permission storage.
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'HRV Trainer backup $stamp',
        text: 'Backup HRV Trainer: $sessCount sessioni, $assCount assessment.',
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: errorColor,
        content: Text('Errore export: $e'),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;

    // Conferma esplicita: l'import è additivo (dedup su startedAt) e quindi
    // non distruttivo, ma vogliamo che l'utente sappia cosa sta facendo
    // e non confonda import con "ripristina da backup sostituendo tutto".
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Importare backup?'),
        content: const Text(
          'Verrà aggiunto allo storico esistente. '
          'Sessioni con stessa data/ora di sessioni già presenti saranno '
          'saltate (nessuna duplicazione, nessuna sovrascrittura).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Scegli file'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) {
        return; // utente ha annullato
      }
      final file = picked.files.single;
      // Preferiamo bytes (withData=true) perché su alcune sorgenti
      // (Drive, content://) il path non è leggibile direttamente.
      final raw = file.bytes != null
          ? utf8.decode(file.bytes!)
          : await File(file.path!).readAsString();

      Map<String, dynamic> data;
      try {
        data = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        messenger.showSnackBar(const SnackBar(
          content: Text('File JSON non valido.'),
        ));
        return;
      }

      final repo = ref.read(sessionRepositoryProvider);
      final result = await repo.importAll(data);

      if (result.isError) {
        messenger.showSnackBar(SnackBar(
          backgroundColor: errorColor,
          content: Text(result.error!),
        ));
        return;
      }

      // Refresh storico + readiness: i provider non si auto-invalidano
      // perché la modifica è venuta dal repository, non da un mutator
      // riverpod-aware.
      ref.invalidate(sessionsListProvider);
      ref.invalidate(readinessProvider);

      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(
          'Importate: ${result.sessionsImported} sessioni, '
          '${result.assessmentsImported} assessment. '
          'Saltate (già presenti): ${result.totalSkipped}.',
        ),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: errorColor,
        content: Text('Errore import: $e'),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Backup',
      enabled: !_busy,
      icon: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.more_vert),
      onSelected: (v) {
        switch (v) {
          case 'export':
            _export();
          case 'import':
            _import();
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'export',
          child: ListTile(
            leading: Icon(Icons.file_download_outlined),
            title: Text('Esporta backup'),
            subtitle: Text('Salva un JSON con tutto lo storico'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'import',
          child: ListTile(
            leading: Icon(Icons.file_upload_outlined),
            title: Text('Importa backup'),
            subtitle: Text('Aggiunge sessioni da un JSON'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

class _FiltersBar extends StatelessWidget {
  final HistoryFilter filter;
  final WidgetRef ref;
  const _FiltersBar({required this.filter, required this.ref});

  // I preset standard usano `int?` per modellare "Tutto" come `null` senza
  // un wrapper dedicato. L'ordine è dal più stretto al più ampio così la
  // selezione progressiva da sinistra a destra è naturale per l'utente.
  static const List<int?> _presetDays = [7, 30, 60, null];

  bool _isPreset(int? days) => _presetDays.contains(days);

  String _labelForPreset(int? d) => d == null ? 'Tutto' : '$d gg';

  void _selectPreset(int? days) {
    ref.read(historyFilterProvider.notifier).state =
        filter.copyWith(days: days);
  }

  Future<void> _openCustomDialog(BuildContext context) async {
    final picked = await showDialog<int?>(
      context: context,
      builder: (ctx) => _CustomDaysDialog(initial: filter.days ?? 30),
    );
    if (picked == null) return;
    // picked == 0 (gestito dal dialog) significa "annullato" → ignoriamo.
    // picked == -1 è il sentinel per "Tutto" scelto dal dialog stesso.
    if (picked == -1) {
      _selectPreset(null);
    } else if (picked > 0) {
      ref.read(historyFilterProvider.notifier).state =
          filter.copyWith(days: picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final customSelected = !_isPreset(filter.days);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Finestra:'),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  // I 4 preset + "Personalizza" non entrano quasi mai in un
                  // SegmentedButton su smartphone — passiamo a chip
                  // scrollabili orizzontalmente per evitare overflow su
                  // device piccoli e per supportare il valore custom.
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final d in _presetDays)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(_labelForPreset(d)),
                            selected: filter.days == d,
                            onSelected: (_) => _selectPreset(d),
                          ),
                        ),
                      ChoiceChip(
                        avatar: const Icon(Icons.edit_outlined, size: 16),
                        // Quando un valore custom è attivo lo mostriamo come
                        // label del chip "Personalizza" — così l'utente vede
                        // a colpo d'occhio quale finestra sta filtrando senza
                        // dover riaprire il dialog.
                        label: Text(
                          customSelected ? '${filter.days} gg' : 'Personalizza',
                        ),
                        selected: customSelected,
                        onSelected: (_) => _openCustomDialog(context),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                ChoiceChip(
                  label: const Text('Tutti'),
                  selected: filter.tag == null,
                  onSelected: (_) {
                    ref.read(historyFilterProvider.notifier).state =
                        filter.copyWith(clearTag: true);
                  },
                ),
                ...SessionTag.values.map((t) => Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text(t.label),
                        selected: filter.tag == t,
                        onSelected: (_) {
                          ref.read(historyFilterProvider.notifier).state =
                              filter.copyWith(tag: t);
                        },
                      ),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog per scegliere una finestra storico custom (in giorni) o "Tutto".
///
/// Ritorna:
///  - un intero positivo > 0 = numero di giorni scelto
///  - -1 = scelto "Tutto"
///  - null = annullato (oppure input invalido, fail-soft)
class _CustomDaysDialog extends StatefulWidget {
  final int initial;
  const _CustomDaysDialog({required this.initial});

  @override
  State<_CustomDaysDialog> createState() => _CustomDaysDialogState();
}

class _CustomDaysDialogState extends State<_CustomDaysDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial.toString());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onConfirm() {
    final txt = _ctrl.text.trim();
    final n = int.tryParse(txt);
    if (n == null || n <= 0) {
      setState(() => _error = 'Inserisci un numero > 0');
      return;
    }
    if (n > HistoryFilter.maxCustomDays) {
      setState(() =>
          _error = 'Massimo ${HistoryFilter.maxCustomDays} giorni (~10 anni)');
      return;
    }
    Navigator.of(context).pop(n);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Finestra storico'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Quanti giorni di storico vuoi vedere?'),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Giorni',
              suffixText: 'gg',
              errorText: _error,
            ),
            onSubmitted: (_) => _onConfirm(),
          ),
          const SizedBox(height: 12),
          // Shortcut a "Tutto": evita la frizione di scrivere un numero
          // gigante quando l'utente vuole semplicemente vedere lo storico
          // intero (caso d'uso principale di questo dialog).
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(-1),
            icon: const Icon(Icons.all_inclusive),
            label: const Text('Mostra tutto lo storico'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: _onConfirm,
          child: const Text('Applica'),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined,
                  size: 64, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              const Text('Nessuna sessione nel periodo selezionato'),
            ],
          ),
        ),
      );
}

class _HistoryBody extends StatelessWidget {
  final List<Session> sessions;
  const _HistoryBody({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final chrono = sessions.reversed.toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (chrono.length >= 3) _TrendCard(sessions: chrono),
        const SizedBox(height: 8),
        HrvHistogram(sessions: sessions),
        const SizedBox(height: 8),
        ...sessions.map((s) => _SessionTile(session: s)),
      ],
    );
  }
}

class _TrendCard extends StatelessWidget {
  final List<Session> sessions;
  const _TrendCard({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rmssdSpots = <FlSpot>[];
    final scoreSpots = <FlSpot>[];
    for (var i = 0; i < sessions.length; i++) {
      rmssdSpots.add(FlSpot(i.toDouble(), sessions[i].metrics.rmssdMs));
      scoreSpots.add(FlSpot(i.toDouble(), sessions[i].metrics.hrvScore));
    }
    // interval per i label dell'asse X: almeno 1, mai > numero di sessioni
    // (fl_chart asserta interval <= range). Per liste corte si vede ogni label.
    final xLabelStep = sessions.length <= 1
        ? 1.0
        : (sessions.length / 5).ceil().clamp(1, sessions.length - 1).toDouble();
    final df = DateFormat('dd/MM');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Trend HRV (${sessions.length} sessioni)',
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                Text('Tap punto = dettaglio',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    )),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: LineChart(LineChartData(
                minX: -0.5,
                maxX: (sessions.length - 1) + 0.5,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: scheme.outlineVariant.withValues(alpha: 0.4),
                    strokeWidth: 0.5,
                  ),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 32,
                      getTitlesWidget: (v, _) => Text(
                        v.toStringAsFixed(0),
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      interval: xLabelStep,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= sessions.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            df.format(sessions[i].startedAt.toLocal()),
                            style: theme.textTheme.labelSmall,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border(
                    left: BorderSide(
                        color: scheme.outlineVariant.withValues(alpha: 0.5)),
                    bottom: BorderSide(
                        color: scheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: rmssdSpots,
                    color: scheme.primary,
                    barWidth: 2,
                    dotData: const FlDotData(show: true),
                  ),
                  LineChartBarData(
                    spots: scoreSpots,
                    color: scheme.secondary,
                    barWidth: 2,
                    dashArray: const [4, 4],
                    dotData: const FlDotData(show: true),
                  ),
                ],
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    // Senza queste flag fl_chart disegna il tooltip sempre
                    // sopra al pallino: per i punti con Y alto il tooltip
                    // esce dal canvas e viene clippato dal Viewport del
                    // ListView (sembra nascosto dalla barra dei filtri in
                    // cima). fitInsideVertically lo riposiziona sotto al
                    // punto quando non c'è spazio sopra; fitInsideHorizontally
                    // gestisce lo stesso problema sui punti laterali.
                    fitInsideVertically: true,
                    fitInsideHorizontally: true,
                    tooltipMargin: 8,
                    getTooltipItems: (spots) => spots.map((s) {
                      final i = s.x.toInt();
                      if (i < 0 || i >= sessions.length) return null;
                      final sess = sessions[i];
                      final isRmssd = s.barIndex == 0;
                      final label = isRmssd ? 'RMSSD' : 'Score';
                      return LineTooltipItem(
                        '${df.format(sess.startedAt.toLocal())}\n'
                        '$label: ${s.y.toStringAsFixed(1)}',
                        TextStyle(color: scheme.onInverseSurface),
                      );
                    }).toList(),
                  ),
                  touchCallback: (event, response) {
                    if (event is! FlTapUpEvent) return;
                    final spots = response?.lineBarSpots;
                    if (spots == null || spots.isEmpty) return;
                    final idx = spots.first.x.toInt();
                    if (idx < 0 || idx >= sessions.length) return;
                    final id = sessions[idx].id;
                    if (id != null) {
                      context.push('/history/session/$id');
                    }
                  },
                ),
              )),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _legend(scheme.primary, 'RMSSD (ms)'),
                const SizedBox(width: 16),
                _legend(scheme.secondary, 'HRV score'),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _legend(Color c, String label) => Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label),
        ],
      );
}

class _SessionTile extends StatelessWidget {
  final Session session;
  const _SessionTile({required this.session});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd MMM • HH:mm');
    final id = session.id;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(switch (session.kind) {
            SessionKind.assessment => Icons.tune,
            SessionKind.training => Icons.self_improvement,
            SessionKind.reading => Icons.wb_sunny_outlined,
            SessionKind.freestyle => Icons.air,
          }),
        ),
        title: Text(
          '${session.tag.label} • ${session.pattern.breathsPerMinute.toStringAsFixed(1)} bpm',
        ),
        subtitle: Text(
          '${df.format(session.startedAt.toLocal())} • '
          '${session.duration.inMinutes} min\n'
          'Score ${session.metrics.hrvScore.toStringAsFixed(0)} • '
          'RMSSD ${session.metrics.rmssdMs.toStringAsFixed(0)} • '
          'SDNN ${session.metrics.sdnnMs.toStringAsFixed(0)}',
        ),
        isThreeLine: true,
        trailing: id == null ? null : const Icon(Icons.chevron_right),
        onTap: id == null ? null : () => context.push('/history/session/$id'),
      ),
    );
  }
}
