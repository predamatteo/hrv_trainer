import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hrv_trainer/main.dart';

void main() {
  testWidgets('App avvia senza crash', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: HrvTrainerApp()));
    await tester.pump();
    expect(find.text('HRV Trainer'), findsWidgets);
  });
}
