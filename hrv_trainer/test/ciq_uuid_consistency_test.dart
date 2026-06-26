@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Il `CIQ_APP_UUID` è duplicato a mano in due file di linguaggi diversi
/// (manifest.xml lato watch, GarminCiqBridge.kt lato Android). Devono restare
/// identici: un fork che rigenera l'UUID solo da un lato ottiene un bridge che
/// non aprirà mai l'app giusta sull'orologio, con un fallimento silenzioso e
/// difficile da diagnosticare. Questo test trasforma l'avvertenza in CLAUDE.md
/// in un controllo eseguibile.
///
/// I test girano da `hrv_trainer/`: il manifest è fuori da quella cartella.
void main() {
  final uuid32 = RegExp(r'[0-9a-fA-F]{32}');

  test('CIQ_APP_UUID coincide tra manifest.xml e GarminCiqBridge.kt', () {
    final manifest = File('../hrv_watch_ciq/manifest.xml');
    final bridge = File(
        'android/app/src/main/kotlin/com/dev/hrv_trainer/GarminCiqBridge.kt');

    expect(manifest.existsSync(), isTrue,
        reason: 'manifest non trovato: ${manifest.absolute.path}');
    expect(bridge.existsSync(), isTrue,
        reason: 'bridge non trovato: ${bridge.absolute.path}');

    // Nel manifest l'unico valore a 32 cifre esadecimali è l'id dell'app
    // (gli id dei prodotti sono "instinct2x" ecc.).
    final manifestMatch = uuid32.firstMatch(manifest.readAsStringSync());
    expect(manifestMatch, isNotNull,
        reason: 'nessun UUID a 32 hex nel manifest');

    final bridgeText = bridge.readAsStringSync();
    final bridgeMatch = RegExp(r'CIQ_APP_UUID\s*=\s*"([0-9a-fA-F]{32})"')
        .firstMatch(bridgeText);
    expect(bridgeMatch, isNotNull,
        reason: 'CIQ_APP_UUID non trovato in GarminCiqBridge.kt');

    final manifestUuid = manifestMatch!.group(0)!.toLowerCase();
    final bridgeUuid = bridgeMatch!.group(1)!.toLowerCase();

    expect(
      bridgeUuid,
      manifestUuid,
      reason: 'UUID divergente! manifest=$manifestUuid bridge=$bridgeUuid — '
          'vanno cambiati insieme (vedi CLAUDE.md).',
    );
  });
}
