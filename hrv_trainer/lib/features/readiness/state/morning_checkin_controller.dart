import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/connect_iq/heart_rate_source.dart';
import '../../../shared/connect_iq/hr_source_provider.dart';
import '../../../shared/hrv/breathing_pacer.dart';
import '../../../shared/hrv/hrv_metrics.dart';
import '../../../shared/hrv/morning_reading.dart';
import '../../../shared/hrv/rr_interval.dart';
import '../../../shared/hrv/session_models.dart';
import '../../../shared/storage/session_repository.dart';
import '../../history/history_screen.dart' show sessionsListProvider;
import '../../home/state/readiness_provider.dart';
import 'readiness_providers.dart';

/// Fasi del check-in mattutino.
/// - [idle]: scelta postura/protocollo, pronto a partire.
/// - [measuring]: assestamento + cattura RR a respiro spontaneo.
/// - [review]: misura conclusa, raccolta contesto e salvataggio.
/// - [saved]: lettura persistita.
enum CheckInPhase { idle, measuring, review, saved }

class MorningCheckInState {
  final CheckInPhase phase;
  final Posture posture;
  final MorningProtocol protocol;

  /// True durante i secondi iniziali di assestamento (no raccolta dati).
  final bool settling;

  /// Secondi rimanenti nella fase corrente (assestamento o cattura).
  final int secLeft;

  final int? currentBpm;
  final int sampleCount;

  /// Metriche calcolate al termine della cattura (fase review/saved).
  final HrvMetrics? metrics;
  final int? savedSessionId;

  const MorningCheckInState({
    required this.phase,
    required this.posture,
    required this.protocol,
    this.settling = false,
    this.secLeft = 0,
    this.currentBpm,
    this.sampleCount = 0,
    this.metrics,
    this.savedSessionId,
  });

  MorningCheckInState copyWith({
    CheckInPhase? phase,
    Posture? posture,
    MorningProtocol? protocol,
    bool? settling,
    int? secLeft,
    int? currentBpm,
    int? sampleCount,
    HrvMetrics? metrics,
    int? savedSessionId,
  }) =>
      MorningCheckInState(
        phase: phase ?? this.phase,
        posture: posture ?? this.posture,
        protocol: protocol ?? this.protocol,
        settling: settling ?? this.settling,
        secLeft: secLeft ?? this.secLeft,
        currentBpm: currentBpm ?? this.currentBpm,
        sampleCount: sampleCount ?? this.sampleCount,
        metrics: metrics ?? this.metrics,
        savedSessionId: savedSessionId ?? this.savedSessionId,
      );
}

class MorningCheckInController extends StateNotifier<MorningCheckInState> {
  final Ref ref;
  StreamSubscription<HeartRateEvent>? _sub;
  Timer? _timer;
  DateTime? _phaseStart;
  final List<RrInterval> _window = [];

  /// Secondi di assestamento iniziale prima di iniziare a raccogliere RR:
  /// scarta i primi battiti instabili (attivazione sensore, transitorio).
  static const settleSec = 10;

  MorningCheckInController(this.ref)
      : super(const MorningCheckInState(
          phase: CheckInPhase.idle,
          posture: Posture.seated,
          protocol: MorningProtocol.seated60,
        ));

  void setPosture(Posture p) {
    if (state.phase != CheckInPhase.idle) return;
    state = state.copyWith(posture: p);
  }

  void setProtocol(MorningProtocol p) {
    if (state.phase != CheckInPhase.idle) return;
    state = state.copyWith(protocol: p);
  }

  Future<void> start() async {
    if (state.phase == CheckInPhase.measuring) return;
    _sub?.cancel();
    _timer?.cancel();
    _window.clear();

    final src = ref.read(heartRateSourceProvider);
    final total = settleSec + state.protocol.captureSec;
    // Niente pattern → misura SPONTANEA (nessun pacer). La durata viene
    // comunque inviata al watch così mostra un countdown e ha un auto-stop
    // di backup, ma il telefono è il driver e ferma a fine cattura.
    await src.start(targetDurationSec: total);

    _phaseStart = DateTime.now();
    state = state.copyWith(
      phase: CheckInPhase.measuring,
      settling: true,
      secLeft: settleSec,
      currentBpm: null,
      sampleCount: 0,
    );

    _sub = src.heartRateStream.listen(_onBeat);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final startedAt = _phaseStart;
    if (startedAt == null) return;
    final elapsed = DateTime.now().difference(startedAt).inSeconds;
    final captureTarget = state.protocol.captureSec;
    if (elapsed < settleSec) {
      state = state.copyWith(settling: true, secLeft: settleSec - elapsed);
      return;
    }
    final captureElapsed = elapsed - settleSec;
    if (captureElapsed >= captureTarget) {
      _finish();
      return;
    }
    state = state.copyWith(
      settling: false,
      secLeft: captureTarget - captureElapsed,
    );
  }

  void _onBeat(HeartRateEvent e) {
    final startedAt = _phaseStart;
    if (startedAt == null) return;
    final elapsed = DateTime.now().difference(startedAt).inSeconds;
    final bpm = e.bpm;
    // Raccogli RR solo DOPO l'assestamento.
    if (elapsed >= settleSec) {
      _window.add(e.toRr());
      state = state.copyWith(currentBpm: bpm, sampleCount: _window.length);
    } else {
      state = state.copyWith(currentBpm: bpm);
    }
  }

  Future<void> _finish() async {
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
    final src = ref.read(heartRateSourceProvider);
    await src.stop();
    final metrics = HrvCalculator.compute(_window);
    state = state.copyWith(phase: CheckInPhase.review, metrics: metrics);
  }

  /// Salva la lettura con il contesto raccolto. Ritorna l'id della sessione
  /// (o null se non c'erano metriche valide).
  Future<int?> save(MorningContext context) async {
    final metrics = state.metrics;
    if (metrics == null) return null;
    final now = DateTime.now();
    final started = _phaseStart ?? now;
    final session = Session(
      kind: SessionKind.reading,
      tag: SessionTag.morning,
      startedAt: started,
      endedAt: now,
      pattern: BreathingPattern.resonance6bpm, // placeholder: misura spontanea
      metrics: metrics,
      morning: MorningMeta(
        posture: state.posture,
        protocol: state.protocol,
        context: context,
      ),
    );
    final repo = ref.read(sessionRepositoryProvider);
    final id = await repo.saveSession(session, _window);

    // Refresh di tutto ciò che dipende dalle letture morning.
    ref.invalidate(sessionsListProvider);
    ref.invalidate(readinessProvider);
    // Nasconde subito la card-promemoria in home (check-in di oggi: fatto).
    ref.invalidate(morningCheckInDoneTodayProvider);
    ref.invalidate(morningReadingsProvider);
    ref.invalidate(readinessSectionProvider);
    ref.invalidate(readinessTrendProvider);

    state = state.copyWith(phase: CheckInPhase.saved, savedSessionId: id);
    return id;
  }

  /// Annulla una misura in corso e ferma la sorgente.
  Future<void> cancel() async {
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
    if (state.phase == CheckInPhase.measuring) {
      try {
        await ref.read(heartRateSourceProvider).stop();
      } catch (_) {}
    }
    _window.clear();
    state = MorningCheckInState(
      phase: CheckInPhase.idle,
      posture: state.posture,
      protocol: state.protocol,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

final morningCheckInControllerProvider = StateNotifierProvider.autoDispose<
    MorningCheckInController, MorningCheckInState>(
  (ref) => MorningCheckInController(ref),
);
