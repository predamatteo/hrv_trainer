/// Metriche d'uso raccolte **solo on-device** (nessun invio in rete: vincolo
/// CIQ-only / privacy come feature). Servono a capire se l'idea di utilizzo
/// funziona: l'utente torna? fa il primo respiro? è costante? Qui i dati grezzi;
/// le derivazioni stanno in [summarize] (pure, `now` iniettato per testabilità).
/// Vedi docs/ux-and-usage.md (#13).
class UsageMetrics {
  /// Primo avvio mai registrato (≈ install).
  final DateTime? firstOpenAt;

  /// Istante in cui l'onboarding è stato completato.
  final DateTime? onboardingDoneAt;

  /// Primo respiro mai svolto (prima sessione dal pacer).
  final DateTime? firstBreathAt;

  /// Giorni (solo data, locale, a mezzanotte) in cui l'app è stata aperta,
  /// ordinati dal più vecchio al più recente, senza duplicati.
  final List<DateTime> openDays;

  const UsageMetrics({
    this.firstOpenAt,
    this.onboardingDoneAt,
    this.firstBreathAt,
    this.openDays = const [],
  });

  static const empty = UsageMetrics();

  UsageMetrics copyWith({
    DateTime? firstOpenAt,
    DateTime? onboardingDoneAt,
    DateTime? firstBreathAt,
    List<DateTime>? openDays,
  }) =>
      UsageMetrics(
        firstOpenAt: firstOpenAt ?? this.firstOpenAt,
        onboardingDoneAt: onboardingDoneAt ?? this.onboardingDoneAt,
        firstBreathAt: firstBreathAt ?? this.firstBreathAt,
        openDays: openDays ?? this.openDays,
      );

  Map<String, dynamic> toJson() => {
        'firstOpenAt': firstOpenAt?.millisecondsSinceEpoch,
        'onboardingDoneAt': onboardingDoneAt?.millisecondsSinceEpoch,
        'firstBreathAt': firstBreathAt?.millisecondsSinceEpoch,
        'openDays': openDays.map((d) => d.millisecondsSinceEpoch).toList(),
      };

  factory UsageMetrics.fromJson(Map<String, dynamic> j) {
    DateTime? at(String k) {
      final v = j[k];
      return v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    }

    final days = ((j['openDays'] as List?) ?? const [])
        .whereType<int>()
        .map(DateTime.fromMillisecondsSinceEpoch)
        .toList()
      ..sort();
    return UsageMetrics(
      firstOpenAt: at('firstOpenAt'),
      onboardingDoneAt: at('onboardingDoneAt'),
      firstBreathAt: at('firstBreathAt'),
      openDays: days,
    );
  }

  /// Derivazioni pure per la vista "Statistiche d'uso". [now] è iniettato così
  /// le metriche dipendenti dalla data odierna (streak) sono testabili.
  UsageSummary summarize(DateTime now) {
    final today = _dateOnly(now);
    return UsageSummary(
      activeDays: openDays.length,
      currentStreak: _currentStreak(today),
      returnedD1: _returnedWithin(1, 1),
      returnedD7: _returnedWithin(1, 7),
      timeToFirstBreath: (firstOpenAt != null && firstBreathAt != null)
          ? firstBreathAt!.difference(firstOpenAt!)
          : null,
      onboardingCompleted: onboardingDoneAt != null,
    );
  }

  /// Numero di giorni consecutivi (terminando oggi o ieri) in cui l'app è stata
  /// aperta. Se l'ultimo open è più vecchio di ieri, la streak corrente è 0.
  int _currentStreak(DateTime today) {
    if (openDays.isEmpty) return 0;
    final set = openDays.map(_dateOnly).toSet();
    final yesterday = today.subtract(const Duration(days: 1));
    // Ancoriamo a oggi se aperto oggi, altrimenti a ieri (giornata in corso non
    // ancora "persa"); più indietro = streak interrotta.
    DateTime cursor;
    if (set.contains(today)) {
      cursor = today;
    } else if (set.contains(yesterday)) {
      cursor = yesterday;
    } else {
      return 0;
    }
    var streak = 0;
    while (set.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// True se l'app è stata aperta in almeno un giorno nell'intervallo
  /// [firstOpenDay + loInclusive, firstOpenDay + hiInclusive] (in giorni).
  /// Base delle metriche di ritorno D1 / D7.
  bool _returnedWithin(int loInclusive, int hiInclusive) {
    final first = firstOpenAt;
    if (first == null) return false;
    final d0 = _dateOnly(first);
    final set = openDays.map(_dateOnly).toSet();
    for (var k = loInclusive; k <= hiInclusive; k++) {
      if (set.contains(d0.add(Duration(days: k)))) return true;
    }
    return false;
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}

/// Esito delle derivazioni d'uso, pronto per la UI.
class UsageSummary {
  final int activeDays;
  final int currentStreak;
  final bool returnedD1;
  final bool returnedD7;
  final Duration? timeToFirstBreath;
  final bool onboardingCompleted;

  const UsageSummary({
    required this.activeDays,
    required this.currentStreak,
    required this.returnedD1,
    required this.returnedD7,
    required this.timeToFirstBreath,
    required this.onboardingCompleted,
  });
}
