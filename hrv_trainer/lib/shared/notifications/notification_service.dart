import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// ID del canale Android dei promemoria. STABILE: cambiarlo crea un canale
/// nuovo e l'utente perde le personalizzazioni (suono, vibrazione, priorità)
/// fatte dalle impostazioni di sistema sul canale precedente.
const String kReminderChannelId = 'training_reminders';
const String _channelName = 'Promemoria allenamento';
const String _channelDescription =
    'Ti ricorda di svolgere le sessioni di training HRV.';

/// Uno slot di promemoria (orario + testo) per lo scheduling bufferato della
/// modalità "smart skip".
class ReminderSlot {
  final int hour;
  final int minute;
  final String title;
  final String body;
  const ReminderSlot({
    required this.hour,
    required this.minute,
    required this.title,
    required this.body,
  });
}

/// Wrapper attorno a flutter_local_notifications. Tutta la logica di
/// piattaforma (init timezone, canale, permessi, scheduling) vive qui, così
/// che il resto dell'app parli solo di "promemoria" e non di plugin.
///
/// Le notifiche sono PURAMENTE locali: nessun server, nessun account —
/// coerente col confine "solo device link" del progetto. Lo scheduling è
/// delegato all'AlarmManager dell'OS, quindi i promemoria scattano anche ad
/// app completamente chiusa e — grazie al boot receiver dichiarato nel
/// manifest — sopravvivono al riavvio del telefono.
class NotificationService {
  NotificationService(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Dettagli notifica condivisi dalle due modalità di scheduling. Icona
  /// piccola monocromatica dedicata (`ic_notification`): quella del launcher
  /// apparirebbe come quadrato bianco nella status bar su molte ROM.
  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      kReminderChannelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      icon: 'ic_notification',
    ),
  );

  /// Base degli id notifica per lo scheduling bufferato (modalità skip).
  static const int _reminderIdBase = 1000;

  /// Inizializza plugin, database timezone e canale. Idempotente: chiamabile
  /// a ogni avvio senza effetti collaterali.
  Future<void> init() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    try {
      final localZone = (await FlutterTimezone.getLocalTimezone()).identifier;
      tz.setLocalLocation(tz.getLocation(localZone));
    } catch (_) {
      // Se il device non espone un nome IANA risolvibile restiamo su UTC: lo
      // scheduling potrebbe sfasarsi rispetto all'ora locale, ma è preferibile
      // a un'eccezione in fase di init che bloccherebbe l'intera app.
    }

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
    );

    // Creiamo il canale subito: così compare nelle impostazioni di sistema
    // ancora prima del primo promemoria e le notifiche schedulate non
    // falliscono per "canale inesistente".
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        kReminderChannelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
      ),
    );

    _initialized = true;
  }

  /// Chiede i permessi runtime. Ritorna true se le notifiche sono utilizzabili
  /// (POST_NOTIFICATIONS concesso, oppure Android < 13 dove è implicito).
  /// L'exact-alarm viene richiesto ma NON è bloccante: se negato ricadiamo su
  /// scheduling inexact in [scheduleDailyReminder].
  Future<bool> requestPermissions() async {
    await init();
    final android = _android;
    if (android == null) return false;
    final granted = await android.requestNotificationsPermission() ?? false;
    await android.requestExactAlarmsPermission();
    return granted;
  }

  Future<bool> areNotificationsEnabled() async {
    await init();
    return await _android?.areNotificationsEnabled() ?? false;
  }

  /// Schedula (o ri-schedula) un promemoria giornaliero ripetuto a
  /// [hour]:[minute]. `matchDateTimeComponents: time` dice all'OS di ripeterlo
  /// ogni giorno alla stessa ora, senza che l'app debba essere viva.
  Future<void> scheduleDailyReminder({
    required int id,
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async {
    await init();

    // exactAllowWhileIdle = orario preciso anche in Doze, ma su Android 12+
    // richiede il permesso exact-alarm. Se non concesso usiamo
    // inexactAllowWhileIdle: nessuna friction di permessi, l'orario può
    // slittare di qualche minuto — del tutto accettabile per un promemoria.
    final canExact = await _android?.canScheduleExactNotifications() ?? false;
    final mode = canExact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;

    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: _nextInstanceOf(hour, minute),
      notificationDetails: _details,
      androidScheduleMode: mode,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: 'training_reminder',
    );
  }

  /// Modalità "smart skip": pianifica fino a [bufferDays] giorni di occorrenze
  /// come one-shot. Serve il one-shot (non una serie ripetuta con
  /// `matchDateTimeComponents`) perché un singolo giorno possa essere saltato:
  /// una serie non è cancellabile per singola istanza. Se [skipToday] è true,
  /// le occorrenze di oggi vengono omesse. Va re-armata dal controller a ogni
  /// avvio/resume/sessione così la finestra resta piena. Idempotente.
  Future<void> scheduleBufferedReminders({
    required List<ReminderSlot> slots,
    required bool skipToday,
    int bufferDays = 14,
  }) async {
    await init();
    await _plugin.cancelAll();
    if (slots.isEmpty) return;

    final canExact = await _android?.canScheduleExactNotifications() ?? false;
    final mode = canExact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;

    final now = tz.TZDateTime.now(tz.local);
    var id = _reminderIdBase;
    for (var day = 0; day < bufferDays; day++) {
      if (day == 0 && skipToday) continue;
      final date = now.add(Duration(days: day));
      for (final slot in slots) {
        // Ricostruiamo l'istante dal calendario del giorno + ora/minuto dello
        // slot: evita il drift di un'ora se `add(days)` attraversa un cambio
        // di ora legale.
        final fire = tz.TZDateTime(
            tz.local, date.year, date.month, date.day, slot.hour, slot.minute);
        if (!fire.isAfter(now)) continue; // istante di oggi già passato
        await _plugin.zonedSchedule(
          id: id++,
          title: slot.title,
          body: slot.body,
          scheduledDate: fire,
          notificationDetails: _details,
          androidScheduleMode: mode,
          payload: 'training_reminder',
        );
      }
    }
  }

  Future<void> cancelAll() async {
    await init();
    await _plugin.cancelAll();
  }

  /// Prossima occorrenza di [hour]:[minute] nel fuso locale. Se l'orario di
  /// oggi è già passato, punta a domani — così il primo scatto non cade "nel
  /// passato" (che l'OS mostrerebbe immediatamente).
  tz.TZDateTime _nextInstanceOf(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}

final notificationServiceProvider = Provider<NotificationService>(
  (_) => NotificationService(FlutterLocalNotificationsPlugin()),
);
