import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../shared/connect_iq/hr_source_provider.dart';
import '../../shared/hrv/hrv_metrics.dart';
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

/// Colore stabile per tag: serve a distinguere visivamente contesti
/// fisiologicamente diversi sul trend (un punto post-workout, con vago
/// momentaneamente depresso, NON va letto sulla stessa scala di una lettura
/// mattutina a riposo). I colori sono fissi e indipendenti dal seed Material 3
/// per restare riconoscibili anche fra temi diversi; usiamo tinte sature ma
/// leggibili sia in light che in dark.
Color tagColor(SessionTag tag) => switch (tag) {
      SessionTag.morning => const Color(0xFFF59E0B), // ambra alba
      SessionTag.preWorkout => const Color(0xFF3B82F6), // blu
      SessionTag.postWorkout => const Color(0xFFEF4444), // rosso carico
      SessionTag.sleep => const Color(0xFF8B5CF6), // viola notte
      SessionTag.stress => const Color(0xFFF97316), // arancio allerta
      SessionTag.recovery => const Color(0xFF22C55E), // verde recupero
      SessionTag.general => const Color(0xFF64748B), // grigio neutro
    };

/// ln(RMSSD) robusto: lnRMSSD è la trasformazione standard per normalizzare
/// la distribuzione fortemente skewed dell'RMSSD (la baseline readiness lavora
/// in questo spazio). Per RMSSD <= 0 ritorniamo null così il punto viene
/// escluso dal trend invece di propagare un -inf nel grafico.
double? lnRmssdOf(Session s) {
  final v = s.metrics.rmssdMs;
  if (v <= 0) return null;
  return math.log(v);
}

/// Colore del pallino qualità segnale dalla % di artefatti: <5 verde,
/// <15 ambra, altrimenti rosso. Mappa diretta sulle stesse soglie con cui
/// HrvCalculator declassa la confidenza, così il dot e la label sono coerenti.
Color qualityColor(double artifactPct) {
  if (artifactPct < 5) return const Color(0xFF22C55E);
  if (artifactPct < 15) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
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
        _WeeklyAggregateCard(sessions: chrono),
        HrvHistogram(sessions: sessions),
        const SizedBox(height: 8),
        ...sessions.map((s) => _SessionTile(session: s)),
      ],
    );
  }
}

/// Trend principale in spazio **lnRMSSD**.
///
/// Cambiamenti rispetto alla versione iniziale (che plottava RMSSD lineare +
/// HRV score sullo stesso asse):
///  - Serie primaria = ln(RMSSD): è la trasformazione standard per normalizzare
///    la distribuzione skewed dell'RMSSD ed è lo spazio in cui la readiness
///    calcola baseline/SWC. Confrontare giorni in lnRMSSD evita che un singolo
///    valore alto schiacci visivamente tutto il resto.
///  - Banda baseline ombreggiata = media mobile ± 1 SD del lnRMSSD sulle
///    sessioni mostrate: dà il "corridoio normale". Punti sopra/sotto la banda
///    sono fuori dalla propria variabilità abituale.
///  - Pallini colorati per tag: post-workout, morning, stress... hanno vago
///    in stati fisiologicamente diversi; colorarli evita di leggere come
///    "calo HRV" ciò che è solo un contesto diverso mescolato sulla stessa
///    linea.
///  - L'HRV score (0-100) è stato tolto dall'asse principale (collisione di
///    scala con lnRMSSD ~3-5) e relegato a una sparkline sottile separata.
class _TrendCard extends StatelessWidget {
  final List<Session> sessions;
  const _TrendCard({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Spot lnRMSSD: indici di posizione, non di tempo (asse categorico come
    // nella versione precedente). I valori non finiti vengono saltati ma
    // l'indice X resta allineato all'array `sessions` per il tap-to-detail.
    final lnSpots = <FlSpot>[];
    final lnValues = <double>[]; // per media/SD/CV (solo valori validi)
    for (var i = 0; i < sessions.length; i++) {
      final ln = lnRmssdOf(sessions[i]);
      if (ln == null) continue;
      lnSpots.add(FlSpot(i.toDouble(), ln));
      lnValues.add(ln);
    }
    final scoreSpots = <FlSpot>[
      for (var i = 0; i < sessions.length; i++)
        FlSpot(i.toDouble(), sessions[i].metrics.hrvScore),
    ];

    // Banda baseline: media e SD (campionaria) del lnRMSSD sulle sessioni
    // mostrate. È volutamente una statistica "trailing semplice" sull'intera
    // finestra visibile, non la baseline rolling-7 della readiness: qui serve
    // come riferimento visivo del corridoio normale del periodo guardato.
    final mean = lnValues.isEmpty
        ? 0.0
        : lnValues.reduce((a, b) => a + b) / lnValues.length;
    final sd = lnValues.length < 2
        ? 0.0
        : math.sqrt(lnValues
                .map((v) => (v - mean) * (v - mean))
                .reduce((a, b) => a + b) /
            (lnValues.length - 1));
    final bandLow = mean - sd;
    final bandHigh = mean + sd;

    // CV(lnRMSSD) sugli ultimi 7 giorni: indicatore di stabilità autonomica.
    // È il coefficiente di variazione (SD/media * 100) calcolato in spazio
    // lnRMSSD sulle sole sessioni delle ultime 168h. Alta variabilità = sistema
    // poco stabile / stress accumulato.
    final cv7 = _cvLnLast7Days(sessions);

    // Range Y con un po' di margine attorno a banda e dati per non clippare i
    // pallini estremi né la banda.
    final allY = <double>[...lnValues, bandLow, bandHigh];
    var minY = allY.isEmpty ? 0.0 : allY.reduce(math.min);
    var maxY = allY.isEmpty ? 1.0 : allY.reduce(math.max);
    final pad = (maxY - minY) * 0.12 + 0.05;
    minY -= pad;
    maxY += pad;

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
                Expanded(
                  child: Text('Trend lnRMSSD (${sessions.length} sessioni)',
                      style: theme.textTheme.titleMedium),
                ),
                Text('Tap punto = dettaglio',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    )),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: LineChart(LineChartData(
                minX: -0.5,
                maxX: (sessions.length - 1) + 0.5,
                minY: minY,
                maxY: maxY,
                // Banda baseline ombreggiata: due linee orizzontali invisibili
                // (a bandLow e bandHigh) riempite in mezzo con betweenBarsData.
                // È il modo fl_chart-nativo per una fascia ±1 SD che segue
                // l'asse senza un annotation manuale.
                rangeAnnotations: RangeAnnotations(
                  horizontalRangeAnnotations: [
                    if (lnValues.length >= 2)
                      HorizontalRangeAnnotation(
                        y1: bandLow,
                        y2: bandHigh,
                        color: scheme.primary.withValues(alpha: 0.10),
                      ),
                  ],
                ),
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
                        v.toStringAsFixed(1),
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
                // Linea della media baseline come riferimento al centro della
                // fascia (tratteggiata, neutra).
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    if (lnValues.isNotEmpty)
                      HorizontalLine(
                        y: mean,
                        color: scheme.outline.withValues(alpha: 0.6),
                        strokeWidth: 1,
                        dashArray: const [3, 4],
                      ),
                  ],
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: lnSpots,
                    // Linea neutra di collegamento: il segnale di contesto sta
                    // nei pallini, non nel colore della linea.
                    color: scheme.primary.withValues(alpha: 0.55),
                    barWidth: 2,
                    dotData: FlDotData(
                      show: true,
                      // Pallino colorato per tag della sessione corrispondente.
                      getDotPainter: (spot, _, _, _) {
                        final i = spot.x.toInt();
                        final c = (i >= 0 && i < sessions.length)
                            ? tagColor(sessions[i].tag)
                            : scheme.primary;
                        return FlDotCirclePainter(
                          radius: 3.5,
                          color: c,
                          strokeWidth: 1.2,
                          strokeColor: scheme.surface,
                        );
                      },
                    ),
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
                      return LineTooltipItem(
                        '${df.format(sess.startedAt.toLocal())}\n'
                        '${sess.tag.label}\n'
                        'lnRMSSD ${s.y.toStringAsFixed(2)} '
                        '(RMSSD ${sess.metrics.rmssdMs.toStringAsFixed(0)})',
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
            const SizedBox(height: 10),
            // Stat compatta CV(lnRMSSD) 7gg + legenda banda.
            Wrap(
              spacing: 16,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'CV(lnRMSSD) 7gg: '
                  '${cv7 == null ? '—' : '${cv7.toStringAsFixed(1)}%'}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                _bandLegend(scheme, 'Baseline ±1 SD'),
              ],
            ),
            const SizedBox(height: 8),
            // Sparkline secondaria sottile per l'HRV score (0-100), separata
            // dall'asse principale per evitare la collisione di scala.
            _ScoreSparkline(spots: scoreSpots),
            const SizedBox(height: 8),
            // Legenda dei tag: una sola riga scrollabile coi colori usati nei
            // pallini, così l'utente sa come leggere i contesti.
            SizedBox(
              height: 22,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final t in SessionTag.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _legend(tagColor(t), t.label),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// CV(lnRMSSD) sulle sessioni delle ultime 168h. null se < 2 valori validi.
  static double? _cvLnLast7Days(List<Session> sessions) {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final vals = <double>[];
    for (final s in sessions) {
      if (s.startedAt.isBefore(cutoff)) continue;
      final ln = lnRmssdOf(s);
      if (ln != null) vals.add(ln);
    }
    if (vals.length < 2) return null;
    final m = vals.reduce((a, b) => a + b) / vals.length;
    if (m == 0) return null;
    final variance =
        vals.map((v) => (v - m) * (v - m)).reduce((a, b) => a + b) /
            (vals.length - 1);
    return 100.0 * math.sqrt(variance) / m.abs();
  }

  Widget _legend(Color c, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(label),
        ],
      );

  Widget _bandLegend(ColorScheme scheme, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 12,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              border: Border.all(
                color: scheme.outline.withValues(alpha: 0.5),
                width: 0.5,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Text(label),
        ],
      );
}

/// Sparkline sottile e separata per l'HRV score (0-100). Tenuta fuori dall'asse
/// principale lnRMSSD per non avere due scale incompatibili sullo stesso grafico
/// (lnRMSSD ~3-5 vs score 0-100). Niente assi/griglia: serve solo l'andamento.
class _ScoreSparkline extends StatelessWidget {
  final List<FlSpot> spots;
  const _ScoreSparkline({required this.spots});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (spots.length < 2) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('HRV score (0-100)',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.outline)),
        const SizedBox(height: 2),
        SizedBox(
          height: 36,
          child: LineChart(LineChartData(
            minY: 0,
            maxY: 100,
            minX: spots.first.x - 0.5,
            maxX: spots.last.x + 0.5,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: const FlTitlesData(show: false),
            lineTouchData: const LineTouchData(enabled: false),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                color: scheme.secondary,
                barWidth: 1.5,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: scheme.secondary.withValues(alpha: 0.12),
                ),
              ),
            ],
          )),
        ),
      ],
    );
  }
}

/// Aggregato settimanale del lnRMSSD: bucket per settimana ISO, barre della
/// MEDIA lnRMSSD della settimana con il numero di sessioni come label/tooltip.
///
/// Aggregare per settimana smussa il rumore giornaliero (sonno, idratazione,
/// orario di misura) e rende visibile il trend di fondo dell'adattamento. Pura
/// aggregazione in memoria sulla lista già caricata; non mostrato con meno di
/// 2 settimane di dati (un'unica barra non è un trend).
class _WeeklyAggregateCard extends StatelessWidget {
  final List<Session> sessions;
  const _WeeklyAggregateCard({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final weeks = _aggregateByIsoWeek(sessions);
    if (weeks.length < 2) return const SizedBox.shrink();

    final maxMean = weeks.map((w) => w.meanLn).fold<double>(0, math.max);
    // Label X: data del lunedì della settimana, ridotta per non affollare.
    final df = DateFormat('dd/MM');
    final int labelStep = (weeks.length / 6).ceil().clamp(1, weeks.length);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Media settimanale lnRMSSD',
                      style: theme.textTheme.titleMedium),
                ),
                Text('${weeks.length} settimane',
                    style: theme.textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 150,
              child: BarChart(BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxMean * 1.18 + 0.05,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: scheme.outlineVariant.withValues(alpha: 0.4),
                    strokeWidth: 0.5,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      getTitlesWidget: (v, _) => Text(
                        v.toStringAsFixed(1),
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= weeks.length) {
                          return const SizedBox.shrink();
                        }
                        if (i % labelStep != 0) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            df.format(weeks[i].weekStart),
                            style: theme.textTheme.labelSmall,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    fitInsideVertically: true,
                    fitInsideHorizontally: true,
                    getTooltipItem: (group, _, rod, _) {
                      final w = weeks[group.x];
                      return BarTooltipItem(
                        'Sett. ${df.format(w.weekStart)}\n'
                        'lnRMSSD medio ${w.meanLn.toStringAsFixed(2)}\n'
                        '${w.count} sessioni',
                        TextStyle(color: scheme.onInverseSurface),
                      );
                    },
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < weeks.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: weeks[i].meanLn,
                          color: scheme.primary,
                          width: 14,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ],
                    ),
                ],
              )),
            ),
            const SizedBox(height: 6),
            Text(
              'Ogni barra = media lnRMSSD della settimana; '
              'tocca per il numero di sessioni.',
              style:
                  theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  /// Bucket per settimana ISO (lunedì come inizio), ordinati cronologicamente.
  /// La chiave è il lunedì (a mezzanotte locale) della settimana che contiene
  /// `startedAt`; aggreghiamo solo lnRMSSD validi.
  static List<_WeekBucket> _aggregateByIsoWeek(List<Session> sessions) {
    final byWeek = <DateTime, List<double>>{};
    for (final s in sessions) {
      final ln = lnRmssdOf(s);
      if (ln == null) continue;
      final local = s.startedAt.toLocal();
      // Lunedì della settimana: weekday 1=lun..7=dom → sottrai (weekday-1) gg.
      final day = DateTime(local.year, local.month, local.day);
      final monday = day.subtract(Duration(days: day.weekday - 1));
      (byWeek[monday] ??= <double>[]).add(ln);
    }
    final out = byWeek.entries
        .map((e) => _WeekBucket(
              weekStart: e.key,
              meanLn: e.value.reduce((a, b) => a + b) / e.value.length,
              count: e.value.length,
            ))
        .toList()
      ..sort((a, b) => a.weekStart.compareTo(b.weekStart));
    return out;
  }
}

/// Aggregato di una singola settimana ISO per [_WeeklyAggregateCard].
class _WeekBucket {
  final DateTime weekStart;
  final double meanLn;
  final int count;
  const _WeekBucket({
    required this.weekStart,
    required this.meanLn,
    required this.count,
  });
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
