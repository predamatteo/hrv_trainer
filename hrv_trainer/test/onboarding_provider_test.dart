import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hrv_trainer/shared/profile/onboarding_provider.dart';

void main() {
  test('flag assente → onboarding non visto', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    expect(c.read(onboardingSeenProvider), isFalse); // stato iniziale sincrono
    // read sopra crea il controller e avvia _load(); attende l'event-loop.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.read(onboardingSeenProvider), isFalse);
  });

  test('flag persistito a true viene caricato dal disco', () async {
    SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    c.read(onboardingSeenProvider); // crea il controller → avvia _load()
    await Future<void>.delayed(const Duration(milliseconds: 20)); // _load() async
    expect(c.read(onboardingSeenProvider), isTrue);
  });

  test('markSeen imposta true (sincrono) e persiste', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final future = c.read(onboardingSeenProvider.notifier).markSeen();
    expect(c.read(onboardingSeenProvider), isTrue); // già true prima dell'await
    await future;

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onboarding_seen_v1'), isTrue);
  });

  test('seed sincrono salta il load e parte già a true', () {
    SharedPreferences.setMockInitialValues({}); // disco vuoto
    final c = ProviderContainer(overrides: [
      onboardingSeenProvider.overrideWith((ref) => OnboardingController(seed: true)),
    ]);
    addTearDown(c.dispose);

    expect(c.read(onboardingSeenProvider), isTrue);
  });
}
