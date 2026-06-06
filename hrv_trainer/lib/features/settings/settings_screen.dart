import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../shared/connect_iq/heart_rate_source.dart';
import '../../shared/connect_iq/hr_source_provider.dart';
import '../../shared/notifications/reminder_settings.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(reminderControllerProvider);
    final controller = ref.read(reminderControllerProvider.notifier);
    final hrSrc = ref.watch(heartRateSourceProvider);
    final stateAsync = ref.watch(hrSourceStateProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _SectionLabel('Orologio', style: theme.textTheme.titleSmall),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _DeviceCard(source: hrSrc, state: stateAsync.value),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('Promemoria di allenamento'),
            subtitle: const Text(
              'Notifiche per ricordarti le sessioni, anche ad app chiusa.',
            ),
            value: settings.enabled,
            onChanged: (v) => _onToggle(context, controller, v),
          ),
          if (settings.enabled) ...[
            SwitchListTile(
              secondary: const Icon(Icons.do_not_disturb_on_outlined),
              title: const Text('Salta se hai già allenato oggi'),
              subtitle: const Text(
                'Non ti disturba se risulti già allenato in giornata. '
                'Best-effort: richiede che l\'app venga aperta nel corso '
                'della giornata.',
              ),
              value: settings.skipIfTrained,
              onChanged: (v) => controller.setSkipIfTrained(v),
            ),
            const Divider(height: 1),
            _SectionLabel('Orari', style: theme.textTheme.titleSmall),
            if (settings.times.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'Nessun orario impostato. Aggiungine uno o usa un preset qui sotto.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final t in settings.times)
              ListTile(
                leading: const Icon(Icons.alarm),
                title: Text(_fmt(context, t)),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Rimuovi',
                  onPressed: () => controller.removeTime(t),
                ),
                onTap: () => _editTime(context, controller, t),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Aggiungi orario'),
                  onPressed: () => _addTime(context, controller),
                ),
              ),
            ),
            const Divider(height: 1),
            _SectionLabel('Preset', style: theme.textTheme.titleSmall),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.wb_sunny_outlined, size: 18),
                    label: const Text('Mattina 08:00'),
                    onPressed: () =>
                        controller.applyPreset(const [ReminderPresets.morning]),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.nightlight_outlined, size: 18),
                    label: const Text('Sera 20:30'),
                    onPressed: () =>
                        controller.applyPreset(const [ReminderPresets.evening]),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.repeat, size: 18),
                    label: const Text('Mattina + sera'),
                    onPressed: () => controller.applyPreset(
                      const [ReminderPresets.morning, ReminderPresets.evening],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                'Suggerimento: per promemoria sempre puntuali, escludi HRV '
                'Trainer dall\'ottimizzazione batteria nelle impostazioni di '
                'sistema. Senza permesso "sveglie precise" l\'orario può '
                'slittare di qualche minuto.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _onToggle(
    BuildContext context,
    ReminderController controller,
    bool value,
  ) async {
    if (!value) {
      await controller.disable();
      return;
    }
    final ok = await controller.enable();
    if (!ok && context.mounted) {
      // Permesso negato: spieghiamo e offriamo la scorciatoia alle
      // impostazioni di sistema (se l'utente l'ha negato in modo permanente,
      // il dialog di sistema non riapparirebbe).
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Permesso notifiche negato. Abilitalo dalle impostazioni di sistema.',
          ),
          action: SnackBarAction(label: 'Apri', onPressed: openAppSettings),
        ),
      );
    }
  }

  Future<void> _addTime(
    BuildContext context,
    ReminderController controller,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
      helpText: 'Orario promemoria',
    );
    if (picked != null) {
      await controller.addTime(ReminderTime(picked.hour, picked.minute));
    }
  }

  Future<void> _editTime(
    BuildContext context,
    ReminderController controller,
    ReminderTime current,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      helpText: 'Modifica orario',
    );
    if (picked != null) {
      await controller.replaceTime(
        current,
        ReminderTime(picked.hour, picked.minute),
      );
    }
  }

  String _fmt(BuildContext context, ReminderTime t) =>
      TimeOfDay(hour: t.hour, minute: t.minute).format(context);
}

class _DeviceCard extends StatelessWidget {
  final HeartRateSource source;
  final HrSourceState? state;

  const _DeviceCard({required this.source, required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final st = state ?? HrSourceState.disconnected;
    final connected = st == HrSourceState.connected;
    final connecting = st == HrSourceState.connecting;
    final color = switch (st) {
      HrSourceState.connected => theme.colorScheme.primary,
      HrSourceState.error => theme.colorScheme.error,
      _ => theme.colorScheme.outline,
    };
    final label = switch (st) {
      HrSourceState.connected => 'Connesso',
      HrSourceState.connecting => 'Connessione…',
      HrSourceState.error => 'Errore di connessione',
      HrSourceState.noDevice => 'Nessun orologio trovato',
      HrSourceState.disconnected => 'Disconnesso',
    };
    // Il bottone gestisce SOLO il link BT (connessione/riconnessione), NON
    // l'avvio di una sessione. Prima "Connetti" chiamava source.start(), che
    // faceva partire una sessione fantasma sul watch (nessuna durata → niente
    // auto-stop = orologio che "continua ad andare"). Le sessioni si avviano
    // ora esclusivamente dalle loro schermate (Training/Assessment/Check-in).
    final btnLabel = switch (st) {
      HrSourceState.noDevice => 'Cerca orologio',
      HrSourceState.connected => 'Riconnetti',
      _ => 'Connetti',
    };
    final Widget trailing;
    if (connecting) {
      trailing = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (connected) {
      // Connesso: riconnessione disponibile ma defilata (caso recovery).
      trailing = TextButton(
        onPressed: () => source.reconnect(),
        child: Text(btnLabel),
      );
    } else {
      trailing = FilledButton.tonal(
        onPressed: () => source.reconnect(),
        child: Text(btnLabel),
      );
    }
    return Card(
      child: ListTile(
        leading: Icon(Icons.watch_outlined, color: color, size: 32),
        title: Text(source.displayName),
        subtitle: Text(label),
        trailing: trailing,
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final TextStyle? style;
  const _SectionLabel(this.text, {this.style});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text, style: style),
      );
}
