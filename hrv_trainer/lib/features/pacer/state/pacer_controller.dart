import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vibration/vibration.dart';

import '../../../shared/hrv/breathing_pacer.dart';

class PacerPreferences {
  final BreathingPattern pattern;
  final bool hapticsEnabled;
  final bool soundEnabled;

  const PacerPreferences({
    required this.pattern,
    this.hapticsEnabled = true,
    this.soundEnabled = false,
  });

  PacerPreferences copyWith({
    BreathingPattern? pattern,
    bool? hapticsEnabled,
    bool? soundEnabled,
  }) =>
      PacerPreferences(
        pattern: pattern ?? this.pattern,
        hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
        soundEnabled: soundEnabled ?? this.soundEnabled,
      );
}

final pacerPreferencesProvider =
    StateProvider<PacerPreferences>((ref) => const PacerPreferences(
          pattern: BreathingPattern.resonance6bpm,
        ));

class PacerTick {
  final BreathingPhase phase;
  final double progress;
  final double amplitude;
  final double elapsedSec;

  const PacerTick({
    required this.phase,
    required this.progress,
    required this.amplitude,
    required this.elapsedSec,
  });
}

/// Pacer respiratorio: emette PacerTick a ~20 Hz mentre è attivo, basandosi
/// su un Stopwatch interno (no dipendenza da TickerProvider, no auto-dispose
/// race con widget tree). Le preferences vengono lette dal Ref ad ogni tick
/// così cambiare pattern non ricrea il controller né interrompe l'animazione.
class PacerController extends StateNotifier<PacerTick> {
  final Ref _ref;
  Timer? _timer;
  final Stopwatch _watch = Stopwatch();
  // Offset aggiunto all'elapsed dello Stopwatch per ancorare il pacer del
  // phone allo stesso t=0 del watch (mStartMs). Quando il phone fa partire il
  // ticker, il watch respira già da `_startOffset`: senza, il cerchio del
  // phone resterebbe indietro di tutta la latenza BT/openApplication (fino a
  // ~17 s). Vale 0 nel pacer "libero" (PacerScreen) dove non c'è watch.
  Duration _startOffset = Duration.zero;
  BreathingPhase? _lastPhase;
  bool _hasVibrator = false;

  PacerController(this._ref)
      : super(const PacerTick(
          phase: BreathingPhase.inhale,
          progress: 0,
          amplitude: 0,
          elapsedSec: 0,
        )) {
    _init();
  }

  PacerPreferences get prefs => _ref.read(pacerPreferencesProvider);

  Future<void> _init() async {
    _hasVibrator = await Vibration.hasVibrator();
  }

  // 50ms = 20 Hz. Più che sufficiente per fluidità del cerchio respiro
  // (pattern lenti 0.1 Hz) ed evita rebuild eccessivi del widget tree.
  static const _tickInterval = Duration(milliseconds: 50);

  /// [startOffset] ancora il pacer al t=0 del watch: l'elapsed effettivo
  /// parte da questo valore invece che da zero, così la fase ispira/espira
  /// combacia con quella del watch (master) anche se il phone avvia il
  /// ticker decine di secondi dopo che il watch ha fissato mStartMs.
  void start({Duration startOffset = Duration.zero}) {
    if (_timer != null) {
      debugPrint('[PACER] start IGNORED (already running)');
      return;
    }
    debugPrint('[PACER] start offset=${startOffset.inMilliseconds}ms');
    _startOffset = startOffset;
    _watch
      ..reset()
      ..start();
    _timer = Timer.periodic(_tickInterval, (_) => _tick());
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    _watch.stop();
  }

  void resume() {
    if (_timer != null) return;
    _watch.start();
    _timer = Timer.periodic(_tickInterval, (_) => _tick());
  }

  int _tickCount = 0;
  void _tick() {
    if (!mounted) return;
    _tickCount++;
    // Elapsed effettivo = Stopwatch + offset di allineamento al watch. È
    // questo (non _watch puro) a guidare la fase, altrimenti il pacer del
    // phone ripartirebbe da zero restando indietro rispetto al watch.
    final elapsedMs = _watch.elapsed.inMilliseconds + _startOffset.inMilliseconds;
    if (_tickCount == 1 || _tickCount % 100 == 0) {
      debugPrint('[PACER] tick #$_tickCount elapsed=${elapsedMs}ms');
    }
    final s = pacerAt(prefs.pattern, elapsedMs / 1000.0);
    state = PacerTick(
      phase: s.phase,
      progress: s.progress,
      amplitude: s.amplitude,
      elapsedSec: s.elapsedSec,
    );
    if (_lastPhase != s.phase) {
      _lastPhase = s.phase;
      _onPhaseChange(s.phase);
    }
  }

  void _onPhaseChange(BreathingPhase phase) {
    if (prefs.hapticsEnabled && _hasVibrator) {
      final ms = switch (phase) {
        BreathingPhase.inhale => 40,
        BreathingPhase.exhale => 60,
        _ => 20,
      };
      Vibration.vibrate(duration: ms);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _watch.stop();
    super.dispose();
  }
}

/// NON autoDispose: la combinazione di `ref.read(...).start()` in onPressed
/// + `ref.watch(...)` nei sotto-widget innesca una race con autoDispose che
/// disponeva il controller subito dopo `start()`, ricreandolo poi senza che
/// il Timer.periodic fosse mai partito.
/// Ciclo di vita gestito esplicitamente via start()/pause() dal training
/// screen quando running passa true→false.
final pacerControllerProvider =
    StateNotifierProvider<PacerController, PacerTick>((ref) {
  return PacerController(ref);
});
