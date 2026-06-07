/// Singolo intervallo R-R (o tra picchi PPG): distanza in ms fra due battiti.
class RrInterval {
  final DateTime timestamp;
  final int ms;

  const RrInterval({required this.timestamp, required this.ms});

  bool get isPhysiological => ms >= 300 && ms <= 2000;

  Map<String, dynamic> toJson() => {
        't': timestamp.millisecondsSinceEpoch,
        'ms': ms,
      };

  factory RrInterval.fromJson(Map<String, dynamic> json) => RrInterval(
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
        ms: json['ms'] as int,
      );
}

/// Punto del trace HR live: BPM istantaneo + timestamp del beat. Il timestamp
/// serve a graficare l'HR su un asse temporale reale. Usato sia dal training
/// (con sovrapposizione del pacer) sia dal morning check-in (curva HR spontanea
/// = visualizzazione della RSA).
class HrTracePoint {
  final DateTime timestamp;
  final int bpm;
  const HrTracePoint({required this.timestamp, required this.bpm});
}
