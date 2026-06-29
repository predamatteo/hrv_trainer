import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hrv_trainer/main.dart';
import 'package:hrv_trainer/shared/connect_iq/hr_source_provider.dart';
import 'package:hrv_trainer/shared/profile/onboarding_provider.dart';

void main() {
  testWidgets('App avvia senza crash (onboarding già visto → shell)',
      (WidgetTester tester) async {
    // La Home formatta la data con locale it_IT e legge SharedPreferences (nome
    // utente): inizializziamo entrambi così il pump non lancia in test.
    SharedPreferences.setMockInitialValues({});
    await initializeDateFormatting('it_IT');

    await tester.pumpWidget(
      ProviderScope(
        // Backend mock: evita i method channel Garmin in test e rende il
        // `requestSync()` del sync iniziale del persister un no-op.
        // Seed onboarding=true: il test bypassa main(), quindi seediamo qui o il
        // redirect dirotterebbe su /onboarding e non vedremmo la shell.
        overrides: [
          hrBackendProvider.overrideWith((ref) => HrBackend.mock),
          onboardingSeenProvider
              .overrideWith((ref) => OnboardingController(seed: true)),
        ],
        child: const HrvTrainerApp(),
      ),
    );
    // Scarica il Future.delayed(2s) del sync silenzioso iniziale del
    // RemoteSessionPersister, così non resta un Timer pendente al teardown.
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    // La bottom nav della shell è presente all'avvio (tab Home).
    expect(find.text('Home'), findsWidgets);
    // La card d'ingresso alla cronaca /hrv è agganciata in Home (GAP 3).
    expect(find.text('Andamento HRV'), findsOneWidget);
  });

  testWidgets('Prima apertura (onboarding non visto) mostra l\'onboarding',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await initializeDateFormatting('it_IT');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hrBackendProvider.overrideWith((ref) => HrBackend.mock),
          onboardingSeenProvider
              .overrideWith((ref) => OnboardingController(seed: false)),
        ],
        child: const HrvTrainerApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    // Il redirect dirotta sulla prima schermata di onboarding, non sulla shell.
    expect(find.text('Allena la calma'), findsOneWidget);
    expect(find.text('Home'), findsNothing);
  });
}
