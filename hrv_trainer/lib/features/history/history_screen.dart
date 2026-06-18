import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../shared/connect_iq/hr_source_provider.dart';
import '../../shared/hrv/hrv_metrics.dart';
import '../../shared/hrv/session_chart_utils.dart';
import '../../shared/hrv/session_models.dart';
import '../../shared/hrv/widgets/hrv_histogram.dart';
import '../../shared/hrv/widgets/ln_rmssd_trend_card.dart';
import '../../shared/storage/session_repository.dart';
import '../home/state/readiness_provider.dart';

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
          _FilterSummaryBar(filter: filter, ref: ref),
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

/// Riga compatta a una sola linea che riassume il filtro attivo e fa da
/// trigger per il pannello [_FilterSheet]. Sostituisce le due righe di chip
/// sempre visibili che rubavano spazio verticale in cima allo storico: ora i
/// controlli vivono in un bottom sheet, qui resta solo il contesto ("cosa sto
/// guardando") in forma minimale e on-brand con le card della pagina.
class _FilterSummaryBar extends StatelessWidget {
  final HistoryFilter filter;
  final WidgetRef ref;
  const _FilterSummaryBar({required this.filter, required this.ref});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tagLabel = filter.tag?.label ?? 'Tutti i tipi';
    final summary = '${filter.label} · $tagLabel';
    // Default = ultimi 30 gg, tutti i tipi: quando il filtro è "non default"
    // accendiamo l'icona col colore primario per segnalare che una vista
    // ristretta è attiva (evita di chiedersi "perché vedo poche sessioni?").
    final isFiltered = filter.days != 30 || filter.tag != null;
    final accent = isFiltered ? scheme.primary : scheme.onSurfaceVariant;

    return InkWell(
      onTap: () => _showFilterSheet(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.tune, size: 18, color: accent),
            const SizedBox(width: 10),
            Text('Filtri',
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: scheme.onSurface)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                summary,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            Icon(Icons.expand_more, size: 20, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

void _showFilterSheet(BuildContext context, WidgetRef ref) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _FilterSheet(),
  );
}

/// Pannello dei filtri storico (finestra temporale + tipo di sessione).
///
/// Spostato dalle due righe di chip sempre a vista a un bottom sheet: qui c'è
/// spazio per mostrare TUTTI i tag su più righe (Wrap) senza scroll orizzontale
/// e senza affollare la schermata principale. Watcha [historyFilterProvider]
/// così le selezioni si riflettono in tempo reale sui chip e sulla lista
/// sottostante (il sheet resta aperto: l'utente può combinare più filtri).
class _FilterSheet extends ConsumerWidget {
  const _FilterSheet();

  // Preset dal più stretto al più ampio; `null` = "Tutto" (nessun filtro
  // temporale), modellato senza wrapper dedicato.
  static const List<int?> _presetDays = [7, 30, 60, null];

  bool _isPreset(int? days) => _presetDays.contains(days);

  String _labelForPreset(int? d) => d == null ? 'Tutto' : '$d gg';

  Future<void> _openCustomDialog(
    BuildContext context,
    WidgetRef ref,
    HistoryFilter filter,
  ) async {
    final picked = await showDialog<int?>(
      context: context,
      builder: (ctx) => _CustomDaysDialog(initial: filter.days ?? 30),
    );
    if (picked == null) return;
    final notifier = ref.read(historyFilterProvider.notifier);
    // picked == -1 è il sentinel per "Tutto" scelto dal dialog stesso.
    if (picked == -1) {
      notifier.state = filter.copyWith(days: null);
    } else if (picked > 0) {
      notifier.state = filter.copyWith(days: picked);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(historyFilterProvider);
    final notifier = ref.read(historyFilterProvider.notifier);
    final theme = Theme.of(context);
    final customSelected = !_isPreset(filter.days);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Filtri', style: theme.textTheme.titleLarge),
                ),
                TextButton(
                  // Reset rapido al default (30 gg, tutti i tipi).
                  onPressed: () =>
                      notifier.state = const HistoryFilter(),
                  child: const Text('Reimposta'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Finestra temporale', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final d in _presetDays)
                  ChoiceChip(
                    label: Text(_labelForPreset(d)),
                    selected: filter.days == d,
                    onSelected: (_) =>
                        notifier.state = filter.copyWith(days: d),
                  ),
                ChoiceChip(
                  avatar: const Icon(Icons.edit_outlined, size: 16),
                  // Con un valore custom attivo il chip mostra i giorni scelti
                  // così l'utente vede la finestra senza riaprire il dialog.
                  label: Text(
                    customSelected ? '${filter.days} gg' : 'Personalizza',
                  ),
                  selected: customSelected,
                  onSelected: (_) => _openCustomDialog(context, ref, filter),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Tipo di sessione', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Tutti'),
                  selected: filter.tag == null,
                  onSelected: (_) =>
                      notifier.state = filter.copyWith(clearTag: true),
                ),
                for (final t in SessionTag.values)
                  ChoiceChip(
                    label: Text(t.label),
                    selected: filter.tag == t,
                    onSelected: (_) =>
                        notifier.state = filter.copyWith(tag: t),
                  ),
              ],
            ),
          ],
        ),
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

/// Corpo dello Storico = il REGISTRO: elenco cronologico (newest-first) delle
/// sessioni, filtrabile e con backup. Le viste aggregate/analitiche (trend
/// lnRMSSD, media settimanale, distribuzione, coerenza nel training, HRV per
/// contesto, impatto abitudini) vivono nel cruscotto "Andamento HRV" (rotta
/// /hrv), raggiungibile dalla card "Stato generale HRV" in home.
class _HistoryBody extends StatelessWidget {
  final List<Session> sessions;
  const _HistoryBody({required this.sessions});

  @override
  Widget build(BuildContext context) {
    // I grafici riflettono la lista GIÀ filtrata (periodo + tag): filtrando
    // "Stress" vedi il trend del solo stress. Il trend vuole ordine
    // cronologico (vecchie → recenti); il provider restituisce newest-first.
    final chrono = sessions.reversed.toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (chrono.length >= 3) ...[
          LnRmssdTrendCard(sessions: chrono),
          const SizedBox(height: 8),
        ],
        HrvHistogram(sessions: sessions),
        const SizedBox(height: 8),
        for (final s in sessions) _SessionTile(session: s),
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  final Session session;
  const _SessionTile({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final df = DateFormat('dd MMM • HH:mm');
    final id = session.id;
    final m = session.metrics;
    final qColor = qualityColor(m.percentArtifactual);
    final accent = tagColor(session.tag);

    return Card(
      // Striscia accent a sinistra del colore-tag: a colpo d'occhio distingue
      // i contesti nella lista (un post-workout non si confonde con un morning).
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: accent, width: 4)),
        ),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Icon(switch (session.kind) {
              SessionKind.assessment => Icons.tune,
              SessionKind.training => Icons.self_improvement,
              SessionKind.reading => Icons.wb_sunny_outlined,
              SessionKind.freestyle => Icons.air,
            }),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  '${session.tag.label} • '
                  '${session.pattern.breathsPerMinute.toStringAsFixed(1)} bpm',
                ),
              ),
              // Pallino qualità segnale: verde/ambra/rosso dalla % artefatti.
              Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: qColor, shape: BoxShape.circle),
              ),
            ],
          ),
          subtitle: Text(
            '${df.format(session.startedAt.toLocal())} • '
            '${session.duration.inMinutes} min\n'
            'Score ${m.hrvScore.toStringAsFixed(0)} • '
            'RMSSD ${m.rmssdMs.toStringAsFixed(0)} • '
            'SDNN ${m.sdnnMs.toStringAsFixed(0)}\n'
            // Hint qualità: confidenza + % artefatti, così sessioni rumorose
            // o a bassa affidabilità sono leggibili senza aprire il dettaglio.
            'Affidabilità ${m.confidence.label} • '
            'artefatti ${m.percentArtifactual.toStringAsFixed(0)}%',
          ),
          isThreeLine: true,
          trailing: id == null ? null : const Icon(Icons.chevron_right),
          onTap:
              id == null ? null : () => context.push('/history/session/$id'),
        ),
      ),
    );
  }
}
