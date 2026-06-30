import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/session_repository.dart';
import 'notification_service.dart';

/// Un orario di promemoria nella giornata. Immutabile e confrontabile per
/// poter deduplicare la lista (mai due promemoria alla stessa ora).
@immutable
class ReminderTime implements Comparable<ReminderTime> {
  final int hour;
  final int minute;
  const ReminderTime(this.hour, this.minute);

  int get minutesOfDay => hour * 60 + minute;

  Map<String, dynamic> toJson() => {'h': hour, 'm': minute};
  factory ReminderTime.fromJson(Map<String, dynamic> j) =>
      ReminderTime(j['h'] as int, j['m'] as int);

  @override
  int compareTo(ReminderTime other) =>
      minutesOfDay.compareTo(other.minutesOfDay);

  @override
  bool operator ==(Object other) =>
      other is ReminderTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);
}

@immutable
class ReminderSettings {
  final bool enabled;
  final List<ReminderTime> times;

  /// Se true, lo scheduling salta le occorrenze di un giorno in cui risulta già
  /// completata una sessione (best-effort, vedi [ReminderController._reschedule]).
  final bool skipIfTrained;

  const ReminderSettings({
    this.enabled = false,
    this.times = const [],
    this.skipIfTrained = false,
  });

  static const ReminderSettings empty = ReminderSettings();

  ReminderSettings copyWith({
    bool? enabled,
    List<ReminderTime>? times,
    bool? skipIfTrained,
  }) =>
      ReminderSettings(
        enabled: enabled ?? this.enabled,
        times: times ?? this.times,
        skipIfTrained: skipIfTrained ?? this.skipIfTrained,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'times': times.map((t) => t.toJson()).toList(),
        'skipIfTrained': skipIfTrained,
      };

  factory ReminderSettings.fromJson(Map<String, dynamic> j) => ReminderSettings(
        enabled: j['enabled'] as bool? ?? false,
        times: ((j['times'] as List?) ?? const [])
            .map((e) => ReminderTime.fromJson(e as Map<String, dynamic>))
            .toList(),
        skipIfTrained: j['skipIfTrained'] as bool? ?? false,
      );
}

/// Preset rapidi offerti in UI. L'utente parte da zero (nessun orario imposto
/// al primo avvio, come da scelta di prodotto) ma può applicarli con un tap.
class ReminderPresets {
  static const ReminderTime morning = ReminderTime(8, 0);
  static const ReminderTime evening = ReminderTime(20, 30);
}

/// Sorgente di verità delle preferenze di promemoria. Persiste su
/// SharedPreferences e tiene sincronizzato lo scheduling dell'OS: ogni
/// mutazione ricalcola da zero le notifiche pianificate (cancelAll + schedule),
/// così lo stato dell'OS non diverge mai dalla lista in memoria.
class ReminderController extends StateNotifier<ReminderSettings> {
  ReminderController(this.ref) : super(ReminderSettings.empty) {
    _load();
  }

  final Ref ref;

  static const String _prefsKey = 'reminder_settings_v1';

  /// Base degli id notifica: i promemoria occupano _idBase, _idBase+1, …
  /// Spazio riservato lontano da 0 per non collidere con eventuali notifiche
  /// future di altra natura.
  static const int _idBase = 1000;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        state =
            ReminderSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        // JSON corrotto/incompatibile → ripartiamo da empty senza crashare.
      }
    }
    // Reconcile all'avvio: riallinea l'OS allo stato persistito (utile dopo un
    // cambio di fuso orario o un aggiornamento dell'app). Il boot receiver del
    // plugin copre il riavvio del telefono; questo copre tutto il resto.
    await _reschedule();
  }

  /// Attiva i promemoria previa richiesta permessi. Se l'utente nega il
  /// permesso notifiche lo stato resta disabilitato e ritorniamo false, così
  /// la UI può mostrare la spiegazione e la scorciatoia alle impostazioni.
  Future<bool> enable() async {
    final granted =
        await ref.read(notificationServiceProvider).requestPermissions();
    if (!granted) return false;
    await _update(state.copyWith(enabled: true));
    return true;
  }

  Future<void> disable() => _update(state.copyWith(enabled: false));

  Future<void> setSkipIfTrained(bool value) =>
      _update(state.copyWith(skipIfTrained: value));

  /// Ricalcola lo scheduling rispetto allo stato corrente. Chiamato dai punti
  /// di salvataggio sessione e dal resume. Solo la modalità skip ha bisogno di
  /// riallinearsi a runtime (ricalcola "allenato oggi"); in modalità fissa la
  /// serie ripetuta è già autosufficiente, quindi evitiamo reschedule inutili.
  Future<void> refresh() async {
    if (!state.skipIfTrained) return;
    await _reschedule();
  }

  Future<void> addTime(ReminderTime t) async {
    if (state.times.contains(t)) return;
    final next = [...state.times, t]..sort();
    await _update(state.copyWith(times: next));
  }

  Future<void> removeTime(ReminderTime t) async {
    final next = state.times.where((e) => e != t).toList();
    await _update(state.copyWith(times: next));
  }

  Future<void> replaceTime(ReminderTime oldT, ReminderTime newT) async {
    if (oldT == newT) return;
    final next = state.times.where((e) => e != oldT).toList();
    if (!next.contains(newT)) next.add(newT);
    next.sort();
    await _update(state.copyWith(times: next));
  }

  /// Applica un preset di orari facendo l'UNIONE con quelli esistenti (con
  /// dedup), così "Mattina + sera" si combina con eventuali orari custom invece
  /// di sovrascriverli.
  Future<void> applyPreset(List<ReminderTime> preset) async {
    final merged = {...state.times, ...preset}.toList()..sort();
    await _update(state.copyWith(times: merged));
  }

  Future<void> _update(ReminderSettings next) async {
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(next.toJson()));
    await _reschedule();
  }

  Future<void> _reschedule() async {
    final service = ref.read(notificationServiceProvider);

    // Niente da pianificare → azzera i soli promemoria generici (il promemoria
    // del piano è gestito separatamente e non va toccato).
    if (!state.enabled || state.times.isEmpty) {
      await service.cancelReminders();
      return;
    }

    if (state.skipIfTrained) {
      // Modalità skip: one-shot bufferati che possono saltare oggi se già
      // allenato (una serie ripetuta non è cancellabile per singola istanza).
      // scheduleBufferedReminders fa internamente il cancelAll.
      final skipToday = await _trainedToday();
      final slots = [
        for (final t in state.times)
          ReminderSlot(
            hour: t.hour,
            minute: t.minute,
            title: 'È ora di allenare la tua HRV',
            body: _bodyFor(t),
          ),
      ];
      await service.scheduleBufferedReminders(
        slots: slots,
        skipToday: skipToday,
      );
      return;
    }

    // Modalità fissa: serie giornaliera ripetuta, robusta "per sempre" anche ad
    // app mai aperta. Azzeriamo prima (solo i promemoria generici) per evitare
    // orfani quando un orario viene rimosso (l'id non riprogrammato resterebbe
    // altrimenti schedulato).
    await service.cancelReminders();
    final times = state.times;
    for (var i = 0; i < times.length; i++) {
      await service.scheduleDailyReminder(
        id: _idBase + i,
        hour: times[i].hour,
        minute: times[i].minute,
        title: 'È ora di allenare la tua HRV',
        body: _bodyFor(times[i]),
      );
    }
  }

  /// True se esiste almeno una sessione iniziata oggi (qualsiasi tag). Base del
  /// "salta se hai già allenato oggi".
  Future<bool> _trainedToday() async {
    final repo = ref.read(sessionRepositoryProvider);
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final today = await repo.listSessions(since: start, limit: 1);
    return today.isNotEmpty;
  }

  String _bodyFor(ReminderTime t) {
    // Messaggio leggermente contestuale: al mattino spingiamo il check-in di
    // readiness, più tardi la sessione di risonanza.
    if (t.hour < 12) {
      return 'Inizia con un morning check-in: 2-3 minuti per la tua readiness.';
    }
    return 'Dedica 20 minuti alla respirazione a frequenza di risonanza.';
  }
}

final reminderControllerProvider =
    StateNotifierProvider<ReminderController, ReminderSettings>(
  (ref) => ReminderController(ref),
);
