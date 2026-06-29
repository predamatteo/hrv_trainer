import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/session_repository.dart';
import 'usage_metrics.dart';

/// Store on-device delle metriche d'uso (#13). Persiste in SharedPreferences
/// (chiave [_key]) — **nessun invio in rete**. Espone metodi `record*`
/// idempotenti per i punti chiave dell'idea di utilizzo (apertura, onboarding,
/// primo respiro).
class UsageMetricsStore extends StateNotifier<UsageMetrics> {
  UsageMetricsStore({UsageMetrics? seed}) : super(seed ?? UsageMetrics.empty) {
    if (seed == null) _load();
  }

  static const String _key = 'usage_metrics_v1';

  /// Limite difensivo ai giorni-aperti memorizzati: D1/D7 servono solo nella
  /// prima settimana e la streak nel recente, lo storico vecchio è inutile.
  static const int _maxOpenDays = 400;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      state = UsageMetrics.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // JSON corrotto → resta empty senza crashare.
    }
  }

  Future<void> _save(SharedPreferences prefs) =>
      prefs.setString(_key, jsonEncode(state.toJson()));

  /// Registra un'apertura: fissa [UsageMetrics.firstOpenAt] al primo avvio e
  /// aggiunge (dedup) il giorno odierno. Da chiamare all'avvio e al resume.
  ///
  /// L'`await` viene PRIMA di mutare lo stato di proposito: `recordOpen` è
  /// chiamato in `initState`, e mutare un provider durante il build lancia
  /// `!_dirty`; l'async gap sposta la mutazione fuori dal frame di build.
  Future<void> recordOpen() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = [
      for (final d in state.openDays) DateTime(d.year, d.month, d.day),
    ];
    final hasToday = days.contains(today);
    if (hasToday && state.firstOpenAt != null) return; // niente di nuovo

    if (!hasToday) {
      days.add(today);
      days.sort();
    }
    final capped =
        days.length > _maxOpenDays ? days.sublist(days.length - _maxOpenDays) : days;
    state = state.copyWith(
      openDays: capped,
      firstOpenAt: state.firstOpenAt ?? now,
    );
    await _save(prefs);
  }

  Future<void> recordOnboardingDone() async {
    if (state.onboardingDoneAt != null) return;
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(onboardingDoneAt: DateTime.now());
    await _save(prefs);
  }

  Future<void> recordFirstBreath() async {
    if (state.firstBreathAt != null) return;
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(firstBreathAt: DateTime.now());
    await _save(prefs);
  }
}

final usageMetricsProvider =
    StateNotifierProvider<UsageMetricsStore, UsageMetrics>(
  (ref) => UsageMetricsStore(),
);

/// Derivazioni d'uso pronte per la UI (pure su [usageMetricsProvider]).
final usageSummaryProvider = Provider<UsageSummary>((ref) {
  return ref.watch(usageMetricsProvider).summarize(DateTime.now());
});

/// Quota di sessioni svolte senza orologio (respiro libero a metriche vuote)
/// sul totale. Calcolata dal repository, on-device.
final watchlessShareProvider =
    FutureProvider.autoDispose<({int total, int watchless})>((ref) async {
  final repo = ref.watch(sessionRepositoryProvider);
  final sessions = await repo.listSessions(limit: 100000);
  final watchless = sessions.where((s) => s.metrics.samples == 0).length;
  return (total: sessions.length, watchless: watchless);
});
