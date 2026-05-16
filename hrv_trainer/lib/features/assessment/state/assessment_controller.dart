import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/connect_iq/heart_rate_source.dart';
import '../../../shared/connect_iq/hr_source_provider.dart';
import '../../../shared/hrv/breathing_pacer.dart';
import '../../../shared/hrv/hrv_metrics.dart';
import '../../../shared/hrv/rr_interval.dart';
import '../../../shared/hrv/session_models.dart';
import '../../../shared/storage/session_repository.dart';

/// Step del protocollo di scansione per la frequenza di risonanza.
/// Valori conformi alla guida (sez. 4.2): 6.5 → 4.5 bpm, 2-3 min ciascuno.
const kAssessmentBpmSteps = [6.5, 6.0, 5.5, 5.0, 4.5];
const kStepDurationSec = 150; // 2.5 min per step

enum AssessmentPhase { idle, baseline, scanning, completed }

class AssessmentState {
  final AssessmentPhase phase;
  final int currentStepIndex;
  final Duration elapsedInStep;
  final List<AssessmentStep> completedSteps;
  final List<RrInterval> currentWindow;
  final ResonanceAssessment? result;

  const AssessmentState({
    required this.phase,
    required this.currentStepIndex,
    required this.elapsedInStep,
    required this.completedSteps,
    required this.currentWindow,
    this.result,
  });

  double? get currentBpm {
    if (phase != AssessmentPhase.scanning) return null;
    if (currentStepIndex >= kAssessmentBpmSteps.length) return null;
    return kAssessmentBpmSteps[currentStepIndex];
  }

  BreathingPattern? get currentPattern {
    final b = currentBpm;
    return b == null ? null : BreathingPattern.fromBpm(b);
  }

  AssessmentState copyWith({
    AssessmentPhase? phase,
    int? currentStepIndex,
    Duration? elapsedInStep,
    List<AssessmentStep>? completedSteps,
    List<RrInterval>? currentWindow,
    ResonanceAssessment? result,
  }) =>
      AssessmentState(
        phase: phase ?? this.phase,
        currentStepIndex: currentStepIndex ?? this.currentStepIndex,
        elapsedInStep: elapsedInStep ?? this.elapsedInStep,
        completedSteps: completedSteps ?? this.completedSteps,
        currentWindow: currentWindow ?? this.currentWindow,
        result: result ?? this.result,
      );
}

class AssessmentController extends StateNotifier<AssessmentState> {
  final Ref ref;
  StreamSubscription<HeartRateEvent>? _sub;
  Timer? _timer;
  DateTime? _stepStartedAt;

  AssessmentController(this.ref)
      : super(const AssessmentState(
          phase: AssessmentPhase.idle,
          currentStepIndex: -1,
          elapsedInStep: Duration.zero,
          completedSteps: [],
          currentWindow: [],
        ));

  Future<void> start() async {
    final src = ref.read(heartRateSourceProvider);
    await src.start();
    _sub = src.heartRateStream.listen(_onBeat);
    _goToStep(0);
  }

  void _goToStep(int idx) {
    if (idx >= kAssessmentBpmSteps.length) {
      _finish();
      return;
    }
    _stepStartedAt = DateTime.now();
    final bpm = kAssessmentBpmSteps[idx];
    ref.read(currentPatternProvider.notifier).state =
        BreathingPattern.fromBpm(bpm);
    state = state.copyWith(
      phase: AssessmentPhase.scanning,
      currentStepIndex: idx,
      elapsedInStep: Duration.zero,
      currentWindow: [],
    );
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final elapsed = DateTime.now().difference(_stepStartedAt!);
      state = state.copyWith(elapsedInStep: elapsed);
      if (elapsed.inSeconds >= kStepDurationSec) {
        _completeCurrentStep();
      }
    });
  }

  void _completeCurrentStep() {
    _timer?.cancel();
    final idx = state.currentStepIndex;
    final bpm = kAssessmentBpmSteps[idx];
    final metrics = HrvCalculator.compute(state.currentWindow);
    final step = AssessmentStep(
      bpm: bpm,
      duration: state.elapsedInStep,
      metrics: metrics,
      rrSamples: List.of(state.currentWindow),
    );
    state = state.copyWith(
      completedSteps: [...state.completedSteps, step],
      currentWindow: [],
    );
    _goToStep(idx + 1);
  }

  Future<void> _finish() async {
    _timer?.cancel();
    _sub?.cancel();
    final src = ref.read(heartRateSourceProvider);
    await src.stop();
    final result = ResonanceAssessment.analyze(
        DateTime.now(), state.completedSteps);
    state = state.copyWith(
      phase: AssessmentPhase.completed,
      result: result,
    );
    await ref.read(sessionRepositoryProvider).saveAssessment(result);
  }

  Future<void> cancel() async {
    _timer?.cancel();
    _sub?.cancel();
    final src = ref.read(heartRateSourceProvider);
    await src.stop();
    state = const AssessmentState(
      phase: AssessmentPhase.idle,
      currentStepIndex: -1,
      elapsedInStep: Duration.zero,
      completedSteps: [],
      currentWindow: [],
    );
  }

  void _onBeat(HeartRateEvent e) {
    // include solo l'ultimo 80% della finestra per escludere adattamento.
    final stepStart = _stepStartedAt;
    if (stepStart == null) return;
    final elapsed = DateTime.now().difference(stepStart);
    final warmup =
        Duration(seconds: (kStepDurationSec * 0.2).round());
    if (elapsed < warmup) return;
    state = state.copyWith(
      currentWindow: [...state.currentWindow, e.toRr()],
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

final assessmentControllerProvider =
    StateNotifierProvider.autoDispose<AssessmentController, AssessmentState>(
        (ref) => AssessmentController(ref));
