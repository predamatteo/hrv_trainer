import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bluetooth_state.dart';
import 'heart_rate_source.dart';
import 'hr_source_provider.dart';

/// Prontezza complessiva a misurare con il watch, combinando lo stato del
/// Bluetooth del telefono (livello OS) con lo stato del link Connect IQ.
///
/// Ordine di precedenza: il Bluetooth spento "vince" su tutto (senza BT il
/// telefono non può proprio raggiungere il Garmin), poi si ricade sullo stato
/// del device Garmin. Stati BT transitori/ambigui (`unknown`, `unauthorized`,
/// `unavailable`) NON vengono trattati come "spento": in quei casi ci fidiamo
/// dello stato Garmin (la verità arriva comunque da Garmin Connect Mobile), così
/// un permesso BLE non concesso al plugin non blocca un setup funzionante.
enum WatchReadiness {
  /// Bluetooth del telefono spento → azione: attivare il Bluetooth.
  bluetoothOff,

  /// BT acceso ma nessun orologio accoppiato/noto → azione: cercare l'orologio.
  noDevice,

  /// Orologio noto ma non raggiungibile (fuori portata/spento) → riconnetti.
  disconnected,

  /// Handshake in corso.
  connecting,

  /// Link col watch attivo: si può misurare.
  ready,

  /// Errore del SDK Connect IQ (es. Garmin Connect Mobile assente) → riprova.
  error,
}

/// Stato di prontezza combinato, ricalcolato reattivamente al variare del BT
/// del telefono o del link Garmin.
final watchReadinessProvider = Provider<WatchReadiness>((ref) {
  final bt = ref.watch(bluetoothAdapterStateProvider).valueOrNull;
  if (bt == BluetoothAdapterState.off ||
      bt == BluetoothAdapterState.turningOff) {
    return WatchReadiness.bluetoothOff;
  }

  // Lo StreamProvider del link Garmin emette solo ai cambi di stato; sul primo
  // build può non aver ancora emesso. Ricadiamo sullo stato corrente cachato
  // dalla sorgente così la prontezza è corretta anche prima del primo evento.
  final hr =
      ref.watch(hrSourceStateProvider).valueOrNull ??
      ref.read(heartRateSourceProvider).state;

  return switch (hr) {
    HrSourceState.connected => WatchReadiness.ready,
    HrSourceState.connecting => WatchReadiness.connecting,
    HrSourceState.noDevice => WatchReadiness.noDevice,
    HrSourceState.error => WatchReadiness.error,
    HrSourceState.disconnected => WatchReadiness.disconnected,
  };
});

/// Testi e semantica UI per ciascuno stato di prontezza. Tenuti qui (vicino
/// all'enum) così il bottom sheet del gate e l'eventuale badge in Impostazioni
/// restano coerenti.
extension WatchReadinessUi on WatchReadiness {
  bool get isReady => this == WatchReadiness.ready;

  /// Stato non bloccante per avviare? Solo `ready`. `connecting` non basta: il
  /// link non è ancora confermato.
  bool get canStart => this == WatchReadiness.ready;

  String get title => switch (this) {
    WatchReadiness.bluetoothOff => 'Bluetooth spento',
    WatchReadiness.noDevice => 'Nessun orologio',
    WatchReadiness.disconnected => 'Orologio non raggiungibile',
    WatchReadiness.connecting => 'Connessione…',
    WatchReadiness.ready => 'Orologio connesso',
    WatchReadiness.error => 'Errore di connessione',
  };

  String get message => switch (this) {
    WatchReadiness.bluetoothOff =>
      'Il Bluetooth del telefono è spento. Attivalo per parlare con '
          'l\'orologio.',
    WatchReadiness.noDevice =>
      'Nessun Garmin accoppiato risulta raggiungibile. Verifica che '
          'l\'orologio sia acceso e vicino.',
    WatchReadiness.disconnected =>
      'L\'orologio non è raggiungibile via Bluetooth. Avvicinalo e '
          'riconnetti.',
    WatchReadiness.connecting =>
      'Sto stabilendo il collegamento con l\'orologio…',
    WatchReadiness.ready => 'Pronto a misurare.',
    WatchReadiness.error =>
      'Connessione al servizio Garmin non riuscita. Verifica che Garmin '
          'Connect sia installato e riprova.',
  };
}

/// Timeout di attesa del PRIMO battito dopo l'avvio di una misura, prima di
/// dichiarare "nessun dato dall'orologio" e annullare invece di far partire una
/// misura fantasma.
///
/// Volutamente generoso: l'avvio dell'app sul watch via `openApplication` può
/// richiedere fino a ~17 s (memoria progetto sulla latenza START_SESSION), cui
/// si somma l'attivazione del sensore HR e la latenza BT del primo sample.
/// 35 s coprono il caso peggiore osservato senza falsi-negativi, restando
/// lontanissimi dal vecchio comportamento ("aspetta l'intera durata e poi parti
/// comunque").
const kWatchFirstSampleTimeout = Duration(seconds: 35);

/// Finestra di silenzio (nessun nuovo battito) durante una cattura già avviata
/// oltre la quale mostriamo un avviso "connessione persa". Non annulla la
/// misura — i dati già raccolti restano validi — ma segnala all'utente che il
/// flusso si è interrotto. Si pulisce da sé appena i battiti riprendono.
const kWatchStaleDataTimeout = Duration(seconds: 12);
