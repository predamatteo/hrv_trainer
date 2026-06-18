import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Stato dell'adattatore Bluetooth del **telefono** (livello OS), distinto dallo
/// stato del link col watch (`HrSourceState`). Serve a distinguere il caso
/// "Bluetooth spento" — il telefono non può proprio parlare col Garmin — dal
/// caso "BT acceso ma orologio non raggiungibile", così la UI può offrire
/// l'azione giusta ("Attiva Bluetooth" vs "Riconnetti").
///
/// Emette SUBITO il valore corrente (`adapterStateNow`) e poi segue lo stream
/// così la UI reagisce in tempo reale quando l'utente accende/spegne il BT.
/// In caso di piattaforma senza BLE o errore del plugin, l'errore resta
/// confinato a questo provider: chi lo consuma usa `valueOrNull` e ricade sullo
/// stato Garmin (vedi `watchReadinessProvider`), senza falsi "BT spento".
final bluetoothAdapterStateProvider = StreamProvider<BluetoothAdapterState>((
  ref,
) async* {
  yield FlutterBluePlus.adapterStateNow;
  yield* FlutterBluePlus.adapterState;
});

/// Richiede l'attivazione del Bluetooth mostrando il dialog di sistema Android.
/// Ritorna true se il BT risulta acceso al termine, false se l'utente rifiuta o
/// la piattaforma non lo supporta. Best-effort: non lancia mai.
Future<bool> requestEnableBluetooth() async {
  try {
    // turnOn() risolve quando l'adapter raggiunge lo stato `on` (o lancia se
    // l'utente annulla il dialog di sistema). Android-only.
    await FlutterBluePlus.turnOn();
    return FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;
  } catch (_) {
    return false;
  }
}
