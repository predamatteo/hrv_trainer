import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bluetooth_state.dart';
import '../hr_source_provider.dart';
import '../watch_readiness.dart';

/// Gate di pre-volo da chiamare PRIMA di avviare qualunque misura (training,
/// morning check-in, assessment).
///
/// - Se il watch è già pronto, ritorna `true` immediatamente.
/// - Altrimenti scatena una riconnessione e mostra un bottom sheet che spiega
///   il problema e offre l'azione giusta (Attiva Bluetooth / Riconnetti /
///   Cerca orologio). Il foglio si chiude da solo con `true` appena il link
///   diventa pronto.
/// - Ritorna `false` se l'utente annulla: in quel caso la misura NON parte —
///   niente più "aspetta X e parti comunque" senza dati.
Future<bool> ensureWatchReady(BuildContext context, WidgetRef ref) async {
  if (ref.read(watchReadinessProvider).canStart) return true;

  // Ri-aggancio: un handle stale (drop BT mentre l'app era in background) può
  // tenere lo stato fermo su "disconnesso". reconnect() ri-scansiona e ri-emette
  // lo stato reale del device, così il foglio parte dall'informazione giusta e
  // può chiudersi subito se in realtà eravamo già raggiungibili.
  unawaited(ref.read(heartRateSourceProvider).reconnect());

  if (!context.mounted) return false;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _WatchReadinessSheet(),
  );
  return ok ?? false;
}

class _WatchReadinessSheet extends ConsumerStatefulWidget {
  const _WatchReadinessSheet();

  @override
  ConsumerState<_WatchReadinessSheet> createState() =>
      _WatchReadinessSheetState();
}

class _WatchReadinessSheetState extends ConsumerState<_WatchReadinessSheet> {
  /// In attesa che un'azione asincrona dell'utente (attiva BT) si risolva.
  bool _busy = false;

  /// Evita doppi pop quando lo stato diventa `ready` mentre un frame è in volo.
  bool _popped = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final readiness = ref.watch(watchReadinessProvider);

    // Link pronto: chiudiamo il foglio col successo al prossimo frame (non si
    // può fare Navigator.pop durante il build).
    if (readiness.canStart && !_popped) {
      _popped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(true);
      });
    }

    final connecting = readiness == WatchReadiness.connecting || _busy;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  _icon(readiness),
                  color: _color(scheme, readiness),
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    readiness.title,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              readiness.message,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: connecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_actionIcon(readiness)),
              label: Text(_actionLabel(readiness)),
              onPressed: connecting ? null : () => _onPrimaryAction(readiness),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annulla'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onPrimaryAction(WatchReadiness readiness) async {
    if (readiness == WatchReadiness.bluetoothOff) {
      setState(() => _busy = true);
      final enabled = await requestEnableBluetooth();
      if (!mounted) return;
      setState(() => _busy = false);
      if (!enabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Attiva il Bluetooth dal centro di controllo o dalle '
              'impostazioni di sistema.',
            ),
          ),
        );
      }
      // Se attivato, lo stream dell'adapter farà ricalcolare la prontezza e il
      // foglio si aggiornerà (e si chiuderà appena il watch è raggiungibile).
      return;
    }
    // disconnected / noDevice / error: ri-scansiona e ri-aggancia il device.
    unawaited(ref.read(heartRateSourceProvider).reconnect());
  }

  IconData _icon(WatchReadiness r) => switch (r) {
    WatchReadiness.bluetoothOff => Icons.bluetooth_disabled,
    WatchReadiness.noDevice => Icons.watch_off_outlined,
    WatchReadiness.disconnected => Icons.watch_outlined,
    WatchReadiness.connecting => Icons.bluetooth_searching,
    WatchReadiness.ready => Icons.check_circle_outline,
    WatchReadiness.error => Icons.error_outline,
  };

  Color _color(ColorScheme scheme, WatchReadiness r) => switch (r) {
    WatchReadiness.ready => scheme.primary,
    WatchReadiness.error => scheme.error,
    _ => scheme.tertiary,
  };

  IconData _actionIcon(WatchReadiness r) => switch (r) {
    WatchReadiness.bluetoothOff => Icons.bluetooth,
    WatchReadiness.noDevice => Icons.search,
    _ => Icons.refresh,
  };

  String _actionLabel(WatchReadiness r) => switch (r) {
    WatchReadiness.bluetoothOff => 'Attiva Bluetooth',
    WatchReadiness.noDevice => 'Cerca orologio',
    WatchReadiness.connecting => 'Connessione…',
    _ => 'Riconnetti',
  };
}

/// Vista a tutto schermo "in attesa del primo battito dall'orologio", usata
/// dalle schermate di misura nella fase iniziale (dopo l'avvio, prima che il
/// watch invii il primo HR sample). Mostra uno spinner calmo e un'azione per
/// annullare. Sostituisce il vecchio countdown che partiva subito e finiva
/// comunque a vuoto.
class WatchWaitingView extends StatelessWidget {
  final String title;
  final VoidCallback onCancel;

  const WatchWaitingView({
    super.key,
    this.title = 'In attesa dell\'orologio…',
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'L\'orologio sta avviando la misura. Tieni l\'app aperta e '
              'l\'orologio al polso.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 28),
            OutlinedButton(onPressed: onCancel, child: const Text('Annulla')),
          ],
        ),
      ),
    );
  }
}

/// Banner sottile mostrato durante una cattura quando il flusso di battiti si
/// interrompe (connessione persa). Non blocca la misura: i dati già raccolti
/// restano. Si nasconde da sé quando i battiti riprendono.
class WatchConnectionLostBanner extends StatelessWidget {
  const WatchConnectionLostBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bluetooth_disabled,
            size: 16,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Connessione persa: in attesa dell\'orologio…',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
