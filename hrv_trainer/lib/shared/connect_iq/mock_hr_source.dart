import 'dart:async';
import 'dart:math' as math;

import '../hrv/breathing_pacer.dart';
import 'heart_rate_source.dart';
import 'remote_session_summary.dart';

/// Sorgente HR fittizia: simula RSA (Respiratory Sinus Arrhythmia) modulando
/// la frequenza cardiaca attorno a `baselineBpm` in fase con un pattern
/// respiratorio. Utile per sviluppo UI senza watch connesso.
class MockHeartRateSource implements HeartRateSource {
  final double baselineBpm;
  final double amplitudeBpm;
  final BreathingPattern Function() breathingPatternProvider;
  final math.Random _rng = math.Random();

  final _hrController = StreamController<HeartRateEvent>.broadcast();
  final _stateController = StreamController<HrSourceState>.broadcast();

  HrSourceState _state = HrSourceState.disconnected;
  Timer? _tickTimer;
  double _phaseSec = 0;

  MockHeartRateSource({
    this.baselineBpm = 62,
    this.amplitudeBpm = 10,
    required this.breathingPatternProvider,
  });

  @override
  String get displayName => 'Mock (simulatore RSA)';

  @override
  HrSourceState get state => _state;

  @override
  Stream<HrSourceState> get stateStream => _stateController.stream;

  @override
  Stream<HeartRateEvent> get heartRateStream => _hrController.stream;

  @override
  Stream<RemoteSessionSummary> get remoteSessionStream =>
      const Stream<RemoteSessionSummary>.empty();

  void _setState(HrSourceState s) {
    _state = s;
    _stateController.add(s);
  }

  @override
  Future<void> start({BreathingPattern? pattern, int? targetDurationSec}) async {
    if (_state == HrSourceState.connected) return;
    _setState(HrSourceState.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _setState(HrSourceState.connected);
    _scheduleNextBeat();
  }

  void _scheduleNextBeat() {
    final pattern = breathingPatternProvider();
    final p = pacerAt(pattern, _phaseSec);
    // RSA: inhale -> HR sale, exhale -> HR scende
    final phaseSign = switch (p.phase) {
      BreathingPhase.inhale => p.amplitude,
      BreathingPhase.exhale => p.amplitude,
      _ => p.amplitude,
    };
    final offset =
        amplitudeBpm * (2 * phaseSign - 1); // centrata, -amp..+amp
    final noise = (_rng.nextDouble() - 0.5) * 1.5;
    final bpm = (baselineBpm + offset + noise).clamp(40.0, 140.0);
    final rrMs = (60000 / bpm).round();
    final now = DateTime.now();
    _hrController.add(HeartRateEvent(
      timestamp: now,
      bpm: bpm.round(),
      rrMs: rrMs,
    ));
    _phaseSec += rrMs / 1000.0;
    _tickTimer = Timer(Duration(milliseconds: rrMs), _scheduleNextBeat);
  }

  @override
  Future<void> stop() async {
    _tickTimer?.cancel();
    _tickTimer = null;
    _setState(HrSourceState.disconnected);
  }

  @override
  Future<HrvOnDemandResult?> requestHrvOnDemand() async {
    await Future<void>.delayed(const Duration(seconds: 1));
    final rr = List.generate(60, (_) {
      final bpm = baselineBpm + (_rng.nextDouble() - 0.5) * amplitudeBpm;
      return (60000 / bpm).round();
    });
    final mean = rr.reduce((a, b) => a + b) / rr.length;
    final sdnn = math.sqrt(
        rr.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
            rr.length);
    double sq = 0;
    for (var i = 1; i < rr.length; i++) {
      sq += (rr[i] - rr[i - 1]) * (rr[i] - rr[i - 1]).toDouble();
    }
    final rmssd = math.sqrt(sq / (rr.length - 1));
    return HrvOnDemandResult(
      takenAt: DateTime.now(),
      rmssdMs: rmssd.round(),
      sdnnMs: sdnn.round(),
      rrWindowMs: rr,
    );
  }

  @override
  Future<void> sendSummaryAck(int startMs) async {
    // No-op: il mock non parla con un watch reale.
  }

  @override
  Future<void> requestSync({bool force = false}) async {
    // No-op: il mock non ha PendingStore da drenare.
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _hrController.close();
    _stateController.close();
  }
}
