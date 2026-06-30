import 'dart:math' as math;

import '../hrv/breathing_pacer.dart';
import '../hrv/session_models.dart';

export 'post_session_report.dart';

/// Modelli del **Piano di allenamento HRV** — un programma di 4 settimane,
/// flessibile e adattivo, che trasforma le sessioni isolate in un percorso
/// guidato con uno scopo e un traguardo (la ri-valutazione finale).
///
/// Scelte di design ancorate alla letteratura (vedi `docs/` + ricerca interna):
/// - **Ramp graduale, non 5×20 dal giorno 1.** Partire piccoli costruisce
///   competenza (SDT) e abitudine (Lally 2010); dosi troppo alte all'inizio
///   aumentano l'abbandono (Perri/King 2002). La scaletta sale 4→18 min in 4
///   settimane, *success-gated* (si avanza solo completando la settimana).
/// - **Flessibile + tollerante.** Nessun giorno fisso: "X volte a settimana,
///   giorni liberi". Saltare non "rompe" nulla — il livello tiene, non punisce.
/// - **Obiettivo di processo, non un numero.** L'endpoint misurabile è la
///   *% di sessioni completate*, mai l'RMSSD (rumoroso su HR a 1 Hz). I segnali
///   fisiologici restano feedback incoraggiante, non pass/fail.
/// - **Implementation intention.** L'utente sceglie un "quando/dove" che ancora
///   il promemoria a una routine esistente (Gollwitzer; serve rinforzo).

/// Lo "scopo" del piano. Influenza solo la copy motivazionale: il pattern
/// respiratorio è sempre seminato dalla frequenza di risonanza *misurata*
/// nell'assessment, non dal goal.
enum PlanGoal { calm, stress, sleep, resilience }

extension PlanGoalX on PlanGoal {
  String get title => switch (this) {
        PlanGoal.calm => 'Costruisci l\'abitudine della calma',
        PlanGoal.stress => 'Gestisci lo stress',
        PlanGoal.sleep => 'Recupero e sonno',
        PlanGoal.resilience => 'Resilienza generale',
      };

  /// Frase-scopo mostrata in testa al piano (il "perché" a lungo termine).
  String get purpose => switch (this) {
        PlanGoal.calm =>
          'Un respiro guidato al giorno per allenare il sistema nervoso alla calma.',
        PlanGoal.stress =>
          'Allena la risposta di calma per reagire meglio sotto pressione.',
        PlanGoal.sleep =>
          'Respira lento per favorire il recupero parasimpatico la sera.',
        PlanGoal.resilience =>
          'Allena la frequenza di risonanza del cuore, giorno dopo giorno.',
      };

  String get shortLabel => switch (this) {
        PlanGoal.calm => 'Calma',
        PlanGoal.stress => 'Stress',
        PlanGoal.sleep => 'Sonno',
        PlanGoal.resilience => 'Resilienza',
      };

  /// Tag con cui marcare le sessioni del piano: serve solo a contestualizzare
  /// lo storico, non cambia il pattern (seminato dalla risonanza misurata).
  SessionTag get sessionTag => switch (this) {
        PlanGoal.stress => SessionTag.stress,
        PlanGoal.sleep => SessionTag.sleep,
        PlanGoal.resilience => SessionTag.general,
        PlanGoal.calm => SessionTag.general,
      };
}

/// Stato del piano. Un solo piano `active` per volta (vincolo applicato dal
/// repository/controller). `completed` = arrivato al traguardo (pronto per la
/// ri-valutazione); `abandoned` = interrotto dall'utente.
enum PlanStatus { active, completed, abandoned }

extension PlanStatusX on PlanStatus {
  bool get isActive => this == PlanStatus.active;
}

/// Un gradino della scaletta progressiva: durata della sessione e numero di
/// sessioni-obiettivo nella settimana. `index` è 1-based.
class PlanWeek {
  final int index;
  final int durationMin;
  final int targetSessions;

  const PlanWeek({
    required this.index,
    required this.durationMin,
    required this.targetSessions,
  });

  PlanWeek copyWith({int? index, int? durationMin, int? targetSessions}) =>
      PlanWeek(
        index: index ?? this.index,
        durationMin: durationMin ?? this.durationMin,
        targetSessions: targetSessions ?? this.targetSessions,
      );

  Map<String, dynamic> toJson() => {
        'w': index,
        'min': durationMin,
        'n': targetSessions,
      };

  factory PlanWeek.fromJson(Map<String, dynamic> j) => PlanWeek(
        index: (j['w'] as num).toInt(),
        durationMin: (j['min'] as num).toInt(),
        targetSessions: (j['n'] as num).toInt(),
      );
}

/// Scaletta di default a 4 settimane: ramp 4→18 min, frequenza 4→5×/sett.
///
/// La settimana 1 è volutamente "impossibile da fallire" (4 min, 4 volte): a
/// ~6 resp/min anche 4-5 minuti producono già un effetto vagale acuto
/// (Laborde 2021), quindi non è una "dose spazzatura" — dà subito un effetto
/// *sentito* che rinforza la competenza. La settimana 4 raggiunge la sessione
/// piena di risonanza; poi si chiude con la ri-valutazione ("diploma").
///
/// Nota onesta: i minuti esatti sono un default *evidence-informed*
/// (estrapolazione da scienza dell'esercizio + dose-response del respiro), non
/// una curva validata da un RCT sul biofeedback respiratorio. Sono il punto di
/// partenza ragionevole, da affinare — per questo vivono in un'unica costante.
const List<PlanWeek> kDefaultPlanLadder = [
  PlanWeek(index: 1, durationMin: 4, targetSessions: 4),
  PlanWeek(index: 2, durationMin: 8, targetSessions: 5),
  PlanWeek(index: 3, durationMin: 13, targetSessions: 5),
  PlanWeek(index: 4, durationMin: 18, targetSessions: 5),
];

/// Soglia di completamento di una settimana per avanzare di livello: ≥80% del
/// target (Lally: un giorno saltato non deve far ripartire da capo), con un
/// minimo di 1 così che un target piccolo resti raggiungibile.
int planAdvanceThreshold(int targetSessions) =>
    math.max(1, (targetSessions * 0.8).ceil());

/// Il piano di allenamento.
class TrainingPlan {
  final int? id;
  final PlanGoal goal;
  final PlanStatus status;
  final DateTime createdAt;

  /// Inizio del conteggio delle settimane/finestre. Di norma == createdAt.
  final DateTime startedAt;

  /// Quando il piano è stato chiuso (completato o abbandonato). null se attivo.
  final DateTime? endedAt;

  /// Scaletta progressiva materializzata alla creazione (default o con i target
  /// settimanali scelti dall'utente). Persistita così com'è.
  final List<PlanWeek> ladder;

  /// Frequenza di risonanza (respiri/min) misurata nell'assessment, da cui si
  /// semina il pattern respiratorio delle sessioni del piano.
  final double resonanceBpm;

  /// "Quando/dove" scelto dall'utente (implementation intention). Es.
  /// "Dopo la sveglia, prima del caffè". Mostrato e usato per inquadrare il
  /// promemoria. null se non impostato.
  final String? implementationIntention;

  /// Orario del promemoria del piano (minuti dalla mezzanotte). null = nessun
  /// promemoria del piano (il check-in mattutino resta separato).
  final int? reminderMinuteOfDay;

  const TrainingPlan({
    this.id,
    required this.goal,
    this.status = PlanStatus.active,
    required this.createdAt,
    required this.startedAt,
    this.endedAt,
    this.ladder = kDefaultPlanLadder,
    required this.resonanceBpm,
    this.implementationIntention,
    this.reminderMinuteOfDay,
  });

  int get durationWeeks => ladder.length;

  /// Pattern respiratorio del piano, derivato dalla risonanza misurata.
  BreathingPattern get pattern => BreathingPattern.fromBpm(resonanceBpm);

  /// Totale sessioni-obiettivo sull'intero arco (per la barra di progresso
  /// cumulativa che non si azzera mai).
  int get totalTargetSessions =>
      ladder.fold(0, (sum, w) => sum + w.targetSessions);

  int? get reminderHour =>
      reminderMinuteOfDay == null ? null : reminderMinuteOfDay! ~/ 60;
  int? get reminderMinute =>
      reminderMinuteOfDay == null ? null : reminderMinuteOfDay! % 60;

  TrainingPlan copyWith({
    int? id,
    PlanGoal? goal,
    PlanStatus? status,
    DateTime? createdAt,
    DateTime? startedAt,
    DateTime? endedAt,
    bool clearEndedAt = false,
    List<PlanWeek>? ladder,
    double? resonanceBpm,
    String? implementationIntention,
    int? reminderMinuteOfDay,
    bool clearReminder = false,
  }) =>
      TrainingPlan(
        id: id ?? this.id,
        goal: goal ?? this.goal,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
        startedAt: startedAt ?? this.startedAt,
        endedAt: clearEndedAt ? null : (endedAt ?? this.endedAt),
        ladder: ladder ?? this.ladder,
        resonanceBpm: resonanceBpm ?? this.resonanceBpm,
        implementationIntention:
            implementationIntention ?? this.implementationIntention,
        reminderMinuteOfDay: clearReminder
            ? null
            : (reminderMinuteOfDay ?? this.reminderMinuteOfDay),
      );

  Map<String, dynamic> toJson() => {
        'goal': goal.name,
        'status': status.name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'startedAt': startedAt.millisecondsSinceEpoch,
        'endedAt': endedAt?.millisecondsSinceEpoch,
        'ladder': ladder.map((w) => w.toJson()).toList(),
        'rfBpm': resonanceBpm,
        'intention': implementationIntention,
        'reminderMin': reminderMinuteOfDay,
      };

  factory TrainingPlan.fromJson(Map<String, dynamic> j, {int? id}) {
    final ladderRaw = j['ladder'];
    final ladder = ladderRaw is List && ladderRaw.isNotEmpty
        ? ladderRaw
            .whereType<Map>()
            .map((m) => PlanWeek.fromJson(m.cast<String, dynamic>()))
            .toList(growable: false)
        : kDefaultPlanLadder;
    return TrainingPlan(
      id: id,
      goal: PlanGoal.values.firstWhere(
        (g) => g.name == j['goal'],
        orElse: () => PlanGoal.calm,
      ),
      status: PlanStatus.values.firstWhere(
        (s) => s.name == j['status'],
        orElse: () => PlanStatus.active,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (j['createdAt'] as num).toInt()),
      startedAt: DateTime.fromMillisecondsSinceEpoch(
          (j['startedAt'] as num).toInt()),
      endedAt: j['endedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((j['endedAt'] as num).toInt()),
      ladder: ladder,
      resonanceBpm: (j['rfBpm'] as num?)?.toDouble() ?? 6.0,
      implementationIntention: j['intention'] as String?,
      reminderMinuteOfDay: (j['reminderMin'] as num?)?.toInt(),
    );
  }
}

/// Stato derivato del piano (calcolato, mai persistito) — quello che la UI mostra.
class PlanProgress {
  /// Livello/settimana corrente (1-based), avanzato in modo adattivo: ogni
  /// finestra passata in cui hai raggiunto ≥80% del target fa salire di livello;
  /// le finestre mancate tengono il livello (niente punizione).
  final int currentLevel;

  /// Il gradino corrente della scaletta.
  final PlanWeek currentWeek;

  /// Indice della finestra di 7 giorni in corso (0-based dall'inizio piano).
  final int windowIndex;

  /// Sessioni del piano completate nella finestra corrente.
  final int completedThisWindow;

  /// Sessioni completate oggi (per non insistere se hai già fatto).
  final int completedToday;

  /// Totale cumulativo di sessioni del piano completate (non si azzera mai).
  final int totalCompleted;

  /// Totale sessioni-obiettivo dell'arco (per la barra cumulativa).
  final int totalTarget;

  /// Hai raggiunto il traguardo (ultimo livello completato): è ora della
  /// ri-valutazione "diploma".
  final bool reachedGraduation;

  const PlanProgress({
    required this.currentLevel,
    required this.currentWeek,
    required this.windowIndex,
    required this.completedThisWindow,
    required this.completedToday,
    required this.totalCompleted,
    required this.totalTarget,
    required this.reachedGraduation,
  });

  int get targetThisWindow => currentWeek.targetSessions;

  double get windowAdherence => targetThisWindow == 0
      ? 0
      : (completedThisWindow / targetThisWindow).clamp(0.0, 1.0);

  bool get windowComplete => completedThisWindow >= targetThisWindow;

  /// Quota della finestra raggiunta → pronto ad avanzare alla prossima settimana
  /// (mostrato come incoraggiamento; l'avanzamento effettivo è a fine finestra).
  bool get readyToAdvance =>
      completedThisWindow >= planAdvanceThreshold(targetThisWindow);

  /// Progresso cumulativo 0..1 sull'intero arco (milestone che non si azzera).
  double get overallProgress =>
      totalTarget == 0 ? 0 : (totalCompleted / totalTarget).clamp(0.0, 1.0);

  /// Va proposta una sessione oggi? (piano in corso, finestra non completa,
  /// niente già fatto oggi, traguardo non raggiunto).
  bool get recommendToday =>
      !reachedGraduation && !windowComplete && completedToday == 0;

  /// Durata consigliata per la sessione di oggi (minuti).
  int get recommendedDurationMin => currentWeek.durationMin;
}

/// Calcola lo stato del piano in modo **puro e deterministico** dai timestamp
/// delle sessioni completate del piano. Niente stato mutabile che possa
/// "driftare": il livello è sempre una funzione di (inizio piano, completamenti,
/// ora) → facile da testare e impossibile da desincronizzare.
///
/// Le finestre sono blocchi di 7 giorni a partire da [plan.startedAt]. Per ogni
/// finestra *già conclusa* si avanza di un livello se i completamenti hanno
/// raggiunto la soglia (≥80% del target di quel livello), altrimenti il livello
/// tiene. Questo realizza il comportamento adattivo e tollerante: saltare una
/// settimana non fa scendere né "rompe" — semplicemente non si sale.
PlanProgress computePlanProgress(
  TrainingPlan plan,
  List<DateTime> completedAt,
  DateTime now,
) {
  final ladder = plan.ladder;
  final lastLevel = ladder.length;

  // Conteggio completamenti per finestra di 7 giorni.
  int windowOf(DateTime t) {
    final days = t.difference(plan.startedAt).inDays;
    if (days < 0) return -1; // prima dell'inizio: non conta
    return days ~/ 7;
  }

  final nowWindow = math.max(0, windowOf(now));
  final perWindow = <int, int>{};
  var totalCompleted = 0;
  var completedToday = 0;
  final today = DateTime(now.year, now.month, now.day);
  for (final t in completedAt) {
    final w = windowOf(t);
    if (w < 0) continue;
    perWindow[w] = (perWindow[w] ?? 0) + 1;
    totalCompleted++;
    final d = DateTime(t.year, t.month, t.day);
    if (d == today) completedToday++;
  }

  // Avanzamento livello camminando sulle finestre concluse.
  var level = 1;
  var reachedGraduation = false;
  for (var w = 0; w < nowWindow; w++) {
    final target = ladder[level - 1].targetSessions;
    final done = perWindow[w] ?? 0;
    if (done >= planAdvanceThreshold(target)) {
      if (level < lastLevel) {
        level++;
      } else {
        reachedGraduation = true;
      }
    }
  }

  final completedThisWindow = perWindow[nowWindow] ?? 0;
  final currentWeek = ladder[level - 1];

  // Graduation rilevata anche nella finestra corrente se sei all'ultimo livello
  // e hai già raggiunto la soglia (così non resti "bloccato" in attesa del
  // confine settimanale per festeggiare il traguardo).
  if (level == lastLevel &&
      completedThisWindow >= planAdvanceThreshold(currentWeek.targetSessions)) {
    reachedGraduation = true;
  }

  // Se il piano è già stato chiuso, rispettiamo lo stato persistito.
  if (plan.status == PlanStatus.completed) reachedGraduation = true;

  return PlanProgress(
    currentLevel: level,
    currentWeek: currentWeek,
    windowIndex: nowWindow,
    completedThisWindow: completedThisWindow,
    completedToday: completedToday,
    totalCompleted: totalCompleted,
    totalTarget: plan.totalTargetSessions,
    reachedGraduation: reachedGraduation,
  );
}
