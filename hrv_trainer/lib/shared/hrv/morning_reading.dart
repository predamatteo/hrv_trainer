// Metadati di una lettura mattutina (Morning Readiness).
//
// Vivono in una colonna dedicata `morning_meta_json` (DB v3) serializzata
// come JSON. Non importa `session_models.dart` per evitare cicli: è `Session`
// a referenziare MorningMeta, non il contrario.

/// Postura durante la misura. La PPG sovrastima l'attività parasimpatica nelle
/// posture non supine: per confronti corretti la postura va tenuta costante e
/// registrata (cfr. research.md, fattori di confondimento).
enum Posture { supine, seated, standing }

extension PostureX on Posture {
  String get label => switch (this) {
        Posture.supine => 'Supino',
        Posture.seated => 'Seduto',
        Posture.standing => 'In piedi',
      };
}

/// Protocollo della misura mattutina.
/// - [seated60]/[seated180]: respiro SPONTANEO a riposo (corretto per il
///   baseline: niente pacing che gonfi artificialmente RSA/RMSSD).
/// - [paced]: lettura legacy a respiro guidato 6/min (le vecchie sessioni
///   morning pre-feature). Mantenuta per back-compat; idealmente esclusa dal
///   baseline spontaneo una volta accumulate abbastanza letture nuove.
enum MorningProtocol { seated60, seated180, paced }

extension MorningProtocolX on MorningProtocol {
  /// Durata di cattura in secondi (oltre i 10s di assestamento iniziale).
  int get captureSec => switch (this) {
        MorningProtocol.seated60 => 60,
        MorningProtocol.seated180 => 180,
        MorningProtocol.paced => 180,
      };

  bool get isSpontaneous => this != MorningProtocol.paced;

  String get label => switch (this) {
        MorningProtocol.seated60 => 'Spontaneo 60s',
        MorningProtocol.seated180 => 'Spontaneo 3 min',
        MorningProtocol.paced => 'Guidato (legacy)',
      };
}

enum SleepQuality { good, fair, poor, unknown }

extension SleepQualityX on SleepQuality {
  String get label => switch (this) {
        SleepQuality.good => 'Sonno buono',
        SleepQuality.fair => 'Sonno così così',
        SleepQuality.poor => 'Sonno scarso',
        SleepQuality.unknown => '—',
      };
}

/// Fattori di contesto opzionali registrati col check-in: aiutano a
/// disaggregare una lettura bassa (alcol, malattia, stress, ecc.).
class MorningContext {
  final SleepQuality sleep;
  final bool alcohol;
  final bool illness;
  final bool stressed;
  final bool soreness;

  /// Affaticamento soggettivo 1 (fresco) - 5 (sfinito). null = non indicato.
  final int? fatigue;

  const MorningContext({
    this.sleep = SleepQuality.unknown,
    this.alcohol = false,
    this.illness = false,
    this.stressed = false,
    this.soreness = false,
    this.fatigue,
  });

  static const empty = MorningContext();

  /// True se c'è almeno un confondente rilevante da segnalare sul grafico.
  bool get hasFlags =>
      alcohol || illness || stressed || soreness || sleep == SleepQuality.poor;

  Map<String, dynamic> toJson() => {
        'sleep': sleep.name,
        if (alcohol) 'alcohol': true,
        if (illness) 'illness': true,
        if (stressed) 'stressed': true,
        if (soreness) 'soreness': true,
        if (fatigue != null) 'fatigue': fatigue,
      };

  factory MorningContext.fromJson(Map<String, dynamic> j) => MorningContext(
        sleep: SleepQuality.values.firstWhere(
          (s) => s.name == j['sleep'],
          orElse: () => SleepQuality.unknown,
        ),
        alcohol: j['alcohol'] == true,
        illness: j['illness'] == true,
        stressed: j['stressed'] == true,
        soreness: j['soreness'] == true,
        fatigue: (j['fatigue'] as num?)?.toInt(),
      );
}

class MorningMeta {
  final Posture posture;
  final MorningProtocol protocol;
  final MorningContext context;

  const MorningMeta({
    required this.posture,
    required this.protocol,
    this.context = MorningContext.empty,
  });

  MorningMeta copyWith({
    Posture? posture,
    MorningProtocol? protocol,
    MorningContext? context,
  }) =>
      MorningMeta(
        posture: posture ?? this.posture,
        protocol: protocol ?? this.protocol,
        context: context ?? this.context,
      );

  Map<String, dynamic> toJson() => {
        'posture': posture.name,
        'protocol': protocol.name,
        'context': context.toJson(),
      };

  factory MorningMeta.fromJson(Map<String, dynamic> j) => MorningMeta(
        posture: Posture.values.firstWhere(
          (p) => p.name == j['posture'],
          orElse: () => Posture.seated,
        ),
        protocol: MorningProtocol.values.firstWhere(
          (p) => p.name == j['protocol'],
          orElse: () => MorningProtocol.paced,
        ),
        context: j['context'] is Map
            ? MorningContext.fromJson(Map<String, dynamic>.from(j['context']))
            : MorningContext.empty,
      );
}
