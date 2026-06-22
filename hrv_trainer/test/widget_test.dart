import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hrv_trainer/main.dart';
import 'package:hrv_trainer/shared/connect_iq/hr_source_provider.dart';

void main() {
  testWidgets('App avvia senza crash', (WidgetTester tester) async {
    // La Home formatta la data con locale it_IT e legge SharedPreferences (nome
    // utente): inizializziamo entrambi così il pump non lancia in test.
    SharedPreferences.setMockInitialValues({});
    await initializeDateFormatting('it_IT');

    await tester.pumpWidget(
      ProviderScope(
        // Backend mock: evita i method channel Garmin in test e rende il
        // `requestSync()` del sync iniziale del persister un no-op.
        overrides: [hrBackendProvider.overrideWith((ref) => HrBackend.mock)],
        child: const HrvTrainerApp(),
      ),
    );
    // Scarica il Future.delayed(2s) del sync silenzioso iniziale del
    // RemoteSessionPersister, così non resta un Timer pendente al teardown.
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    // La bottom nav della shell è presente all'avvio (tab Home).
    expect(find.text('Home'), findsWidgets);
  });
}
