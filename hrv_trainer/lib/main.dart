import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'shared/connect_iq/hr_source_provider.dart';
import 'shared/connect_iq/remote_session_persister.dart';

void main() {
  runApp(const ProviderScope(child: HrvTrainerApp()));
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
      ref.read(heartRateSourceProvider).requestSync();
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
      routerConfig: appRouter,
    );
  }
}
