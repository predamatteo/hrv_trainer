import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Chiave SharedPreferences del flag onboarding. Esposta perché `main()` la
/// rilegge per seedare sincronicamente il provider prima di `runApp`.
const String kOnboardingSeenKey = 'onboarding_seen_v1';

/// Flag "onboarding già visto". Persistito in SharedPreferences: alla prima
/// apertura (flag assente/`false`) il `redirect` del router dirotta su
/// `/onboarding`; una volta completato ([markSeen]) non si ripresenta più.
///
/// Il costruttore accetta un [seed] **sincrono**: in produzione `main()` legge
/// il valore dalle prefs PRIMA di `runApp` e lo inietta via override, così il
/// redirect di go_router al primo frame vede già il valore giusto e l'utente di
/// ritorno non vede il flicker Home → /onboarding → Home (il `_load()` async
/// arriverebbe troppo tardi e il redirect non si rivaluta da solo). Stesso
/// pattern di persistenza di `user_profile_provider.dart`.
class OnboardingController extends StateNotifier<bool> {
  OnboardingController({bool seed = false}) : super(seed) {
    // Se già seedato a `true` (utente di ritorno) lo stato è corretto e non
    // serve rileggere; sul path non-seedato (es. test senza override, o un
    // accesso prima del seed) carichiamo dal disco.
    if (!seed) _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(kOnboardingSeenKey) ?? false;
  }

  /// Marca l'onboarding come completato e persiste. Imposta lo stato in modo
  /// **sincrono** (prima dell'`await`) così un `context.go('/')` immediato vede
  /// già il flag a `true` nel redirect.
  Future<void> markSeen() async {
    state = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingSeenKey, true);
  }
}

final onboardingSeenProvider = StateNotifierProvider<OnboardingController, bool>(
  (ref) => OnboardingController(),
);
