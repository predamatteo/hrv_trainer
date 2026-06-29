import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'shared/connect_iq/hr_source_provider.dart';
import 'shared/connect_iq/remote_session_persister.dart';
import 'shared/notifications/reminder_settings.dart';
import 'shared/profile/onboarding_provider.dart';
import 'shared/usage/usage_metrics_provider.dart';

Future<void> main() async {
  // Necessario: il warm-up dei provider tocca i plugin (timezone,
  // SharedPreferences, notifiche) durante il primo frame.
  WidgetsFlutterBinding.ensureInitialized();
  // Inizializza i simboli locale italiani: senza questo DateFormat('EEEE d
  // MMMM') renderizzerebbe nomi di mese/giorno in inglese (il default `intl`).
  await initializeDateFormatting('it_IT');
  Intl.defaultLocale = 'it_IT';
  // Legge il flag onboarding PRIMA di runApp e lo inietta come seed sincrono:
  // così il redirect del router al primo frame sa già se mostrare l'onboarding,
  // senza il flicker Home → /onboarding → Home per l'utente di ritorno.
  final prefs = await SharedPreferences.getInstance();
  final onboardingSeen = prefs.getBool(kOnboardingSeenKey) ?? false;
  runApp(
    ProviderScope(
      overrides: [
        onboardingSeenProvider
            .overrideWith((ref) => OnboardingController(seed: onboardingSeen)),
      ],
      child: const HrvTrainerApp(),
    ),
  );
}

class HrvTrainerApp extends ConsumerStatefulWidget {
  const HrvTrainerApp({super.key});

  @override
  ConsumerState<HrvTrainerApp> createState() => _HrvTrainerAppState();
}

class _HrvTrainerAppState extends ConsumerState<HrvTrainerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Istanzia il controller dei promemoria all'avvio: carica le preferenze
    // persistite e riallinea lo scheduling dell'OS (reconcile dopo eventuale
    // cambio di fuso orario o aggiornamento dell'app). Non-autoDispose →
    // resta vivo per tutta la durata dell'app.
    ref.read(reminderControllerProvider);
    // Metriche d'uso locali (#13): registra l'apertura (solo on-device).
    unawaited(ref.read(usageMetricsProvider.notifier).recordOpen());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Quando l'app torna in foreground, chiediamo al watch un sync
    // silenzioso del PendingStore. Recupera SESSION_SUMMARY orfani che
    // erano stati emessi mentre l'app phone era killata: Garmin Connect
    // Mobile non bufferizza i messaggi se nessun listener è registrato
    // in quel momento, quindi il summary resta nel PendingStore del
    // watch finché qualcosa non scatena `flushPendingSummaries`.
    //
    // force=false: se l'app sul watch non è running il messaggio si
    // perde, ma è un sync ricorrente — non vogliamo scatenare il dialog
    // "Avviare HRV Trainer?" ogni volta che l'utente riapre la phone app.
    // Per recovery esplicito c'è il bottone "Sincronizza" in cronologia.
    if (state == AppLifecycleState.resumed) {
      final src = ref.read(heartRateSourceProvider);
      // Ri-aggancia il device handle: se il watch si è ri-connesso in BT mentre
      // l'app era in background, il handle nativo poteva essere rimasto stale e
      // lo stato del telefono fuori sync. reconnect() ri-scansiona e ri-emette
      // lo STATE reale del device, evitando il badge bloccato su "Disconnesso".
      unawaited(src.reconnect());
      src.requestSync();
      // Modalità promemoria "smart skip": riallinea lo scheduling allo stato di
      // oggi quando l'utente torna in app (es. dopo una sessione completata).
      // No-op se la modalità skip è off.
      unawaited(ref.read(reminderControllerProvider.notifier).refresh());
      // Registra anche il rientro come apertura del giorno (dedup interno).
      unawaited(ref.read(usageMetricsProvider.notifier).recordOpen());
    }
  }

  @override
  Widget build(BuildContext context) {
    // Warm-up: assicura che il listener dei SESSION_SUMMARY dal watch sia
    // istanziato prima di qualunque sessione stand-alone.
    ref.watch(remoteSessionPersisterProvider);

    return MaterialApp.router(
      title: 'HRV Trainer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      locale: const Locale('it'),
      supportedLocales: const [Locale('it'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: ref.watch(routerProvider),
    );
  }
}
