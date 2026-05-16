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

/// Utilità di filtering: rimuove artefatti e battiti ectopici secondo il
/// criterio Malik (variazione > 20% rispetto al precedente).
extension RrCleaning on List<RrInterval> {
  List<RrInterval> cleaned() {
    final out = <RrInterval>[];
    for (final rr in this) {
      if (!rr.isPhysiological) continue;
      if (out.isNotEmpty) {
        final prev = out.last.ms;
        final diff = (rr.ms - prev).abs() / prev;
        if (diff > 0.20) continue;
      }
      out.add(rr);
    }
    return out;
  }
}
