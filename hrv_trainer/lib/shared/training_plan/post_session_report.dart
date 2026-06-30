// Report soggettivo post-sessione. Vive in un file a sé perché è un concetto
// a livello di *sessione* (è un campo di `Session`), non solo del piano: tenerlo
// separato evita una dipendenza circolare tra `session_models` e `plan_models`.

/// Sensazioni corporee selezionabili nel report post-sessione (chip). Allenano
/// la consapevolezza interocettiva (MAIA/Garfinkel): notare lo stato interno è
/// il cuore dell'auto-regolazione. `isPositive` serve a colorare il trend.
enum BodySensation {
  slowerBreath,
  relaxedShoulders,
  clearMind,
  calmHeart,
  warmth,
  stillTense,
  lightHead,
  wanderingMind,
}

extension BodySensationX on BodySensation {
  String get label => switch (this) {
        BodySensation.slowerBreath => 'Respiro più lento',
        BodySensation.relaxedShoulders => 'Spalle rilassate',
        BodySensation.clearMind => 'Mente più lucida',
        BodySensation.calmHeart => 'Cuore che rallenta',
        BodySensation.warmth => 'Calore / formicolio',
        BodySensation.stillTense => 'Ancora teso',
        BodySensation.lightHead => 'Testa leggera',
        BodySensation.wanderingMind => 'Mente che vaga',
      };

  bool get isPositive => switch (this) {
        BodySensation.slowerBreath ||
        BodySensation.relaxedShoulders ||
        BodySensation.clearMind ||
        BodySensation.calmHeart ||
        BodySensation.warmth =>
          true,
        BodySensation.stillTense ||
        BodySensation.lightHead ||
        BodySensation.wanderingMind =>
          false,
      };
}

/// Report soggettivo post-sessione (~20s, tutto a tap). Costruito su scale
/// validate ultra-brevi (VAS calma/tensione, valenza tipo SAM) e
/// sull'auto-monitoraggio come ingrediente attivo del cambiamento
/// (Harkin 2016). Tutti i campi sono opzionali: non deve mai bloccare il flusso.
class PostSessionReport {
  /// Tensione PRIMA della sessione, 0–10 (0 = per niente teso, 10 = molto
  /// teso). Catturata sul gate di connettività, prima di misurare.
  final int? tensionPre;

  /// Calma DOPO la sessione, 0–10 (0 = per niente calmo, 10 = molto calmo).
  final int? calmPost;

  /// Valenza dell'umore, 1–5 (1 = molto giù, 5 = molto bene). Riga di emoji.
  final int? mood;

  final List<BodySensation> sensations;
  final String? note;

  const PostSessionReport({
    this.tensionPre,
    this.calmPost,
    this.mood,
    this.sensations = const [],
    this.note,
  });

  /// Variazione di calma entro la sessione, su scala 0–10. Confronta la calma
  /// finale con la calma iniziale stimata (10 − tensione iniziale). È il segnale
  /// soggettivo portante ("+3 calma"), mostrato accanto all'HRV. null se manca
  /// uno dei due estremi.
  int? get calmDelta {
    if (tensionPre == null || calmPost == null) return null;
    final calmPre = 10 - tensionPre!;
    return calmPost! - calmPre;
  }

  bool get isEmpty =>
      tensionPre == null &&
      calmPost == null &&
      mood == null &&
      sensations.isEmpty &&
      (note == null || note!.trim().isEmpty);

  PostSessionReport copyWith({
    int? tensionPre,
    int? calmPost,
    int? mood,
    List<BodySensation>? sensations,
    String? note,
  }) =>
      PostSessionReport(
        tensionPre: tensionPre ?? this.tensionPre,
        calmPost: calmPost ?? this.calmPost,
        mood: mood ?? this.mood,
        sensations: sensations ?? this.sensations,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => {
        if (tensionPre != null) 'pre': tensionPre,
        if (calmPost != null) 'post': calmPost,
        if (mood != null) 'mood': mood,
        if (sensations.isNotEmpty)
          'sens': sensations.map((s) => s.name).toList(),
        if (note != null && note!.trim().isNotEmpty) 'note': note,
      };

  factory PostSessionReport.fromJson(Map<String, dynamic> j) {
    final sensRaw = j['sens'];
    final sensations = sensRaw is List
        ? sensRaw
            .map((name) => BodySensation.values
                .where((s) => s.name == name)
                .cast<BodySensation?>()
                .firstOrNull)
            .whereType<BodySensation>()
            .toList(growable: false)
        : const <BodySensation>[];
    return PostSessionReport(
      tensionPre: (j['pre'] as num?)?.toInt(),
      calmPost: (j['post'] as num?)?.toInt(),
      mood: (j['mood'] as num?)?.toInt(),
      sensations: sensations,
      note: j['note'] as String?,
    );
  }
}
