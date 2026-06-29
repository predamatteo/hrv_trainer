import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/connect_iq/bluetooth_state.dart';
import '../../shared/connect_iq/hr_source_provider.dart';
import '../../shared/connect_iq/watch_readiness.dart';
import '../../shared/notifications/reminder_settings.dart';
import '../../shared/profile/user_profile_provider.dart';
import '../../shared/ui/ui.dart';
import '../../shared/usage/usage_metrics_provider.dart';

/// Tab "Profilo": nome (per il saluto in Home), stato orologio e promemoria.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(reminderControllerProvider);
    final controller = ref.read(reminderControllerProvider.notifier);
    final t = context.tokens;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 18),
              child: Text('Profilo', style: text.headlineSmall),
            ),

            const SectionHeader(title: 'Il tuo profilo'),
            const AppCard(padding: EdgeInsets.fromLTRB(18, 6, 14, 6), child: _NameField()),

            const SizedBox(height: 22),
            const SectionHeader(title: 'Orologio'),
            const _DeviceCard(),

            const SizedBox(height: 22),
            const SectionHeader(title: 'Promemoria'),
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Column(
                children: [
                  _SwitchRow(
                    icon: Icons.notifications_active_outlined,
                    title: 'Promemoria di allenamento',
                    subtitle: 'Notifiche per le sessioni, anche ad app chiusa.',
                    value: settings.enabled,
                    onChanged: (v) => _onToggle(context, controller, v),
                  ),
                  if (settings.enabled) ...[
                    Divider(height: 1, color: t.line),
                    _SwitchRow(
                      icon: Icons.do_not_disturb_on_outlined,
                      title: 'Salta se hai già allenato oggi',
                      subtitle:
                          'Non disturba se risulti già allenato in giornata (best-effort).',
                      value: settings.skipIfTrained,
                      onChanged: controller.setSkipIfTrained,
                    ),
                  ],
                ],
              ),
            ),

            if (settings.enabled) ...[
              const SizedBox(height: 18),
              const SectionHeader(title: 'Orari'),
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                child: Column(
                  children: [
                    if (settings.times.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Nessun orario impostato. Aggiungine uno o usa un preset.',
                            style: text.bodyMedium?.copyWith(color: t.dim),
                          ),
                        ),
                      ),
                    for (final time in settings.times)
                      _TimeRow(
                        label: _fmt(context, time),
                        onTap: () => _editTime(context, controller, time),
                        onDelete: () => controller.removeTime(time),
                        showDivider: time != settings.times.last,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('Aggiungi orario'),
                  onPressed: () => _addTime(context, controller),
                ),
              ),
              const SizedBox(height: 18),
              const SectionHeader(title: 'Preset'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
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
                    onPressed: () => controller.applyPreset(const [
                      ReminderPresets.morning,
                      ReminderPresets.evening,
                    ]),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Suggerimento: per promemoria sempre puntuali, escludi HRV Trainer '
                'dall\'ottimizzazione batteria nelle impostazioni di sistema. Senza '
                'permesso "sveglie precise" l\'orario può slittare di qualche minuto.',
                style: text.bodySmall?.copyWith(color: t.faint),
              ),
            ],

            const SizedBox(height: 22),
            const SectionHeader(title: 'Statistiche d\'uso (locali)'),
            const _UsageStatsCard(),
          ],
        ),
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

  Future<void> _addTime(BuildContext context, ReminderController controller) async {
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
      await controller.replaceTime(current, ReminderTime(picked.hour, picked.minute));
    }
  }

  String _fmt(BuildContext context, ReminderTime t) =>
      TimeOfDay(hour: t.hour, minute: t.minute).format(context);
}

/// Campo nome persistito su [userNameProvider]. Stateful per non resettare il
/// cursore a ogni rebuild: legge il valore iniziale una volta in initState.
class _NameField extends ConsumerStatefulWidget {
  const _NameField();

  @override
  ConsumerState<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends ConsumerState<_NameField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ref.read(userNameProvider) ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return TextField(
      controller: _ctrl,
      textCapitalization: TextCapitalization.words,
      textInputAction: TextInputAction.done,
      onChanged: (v) => ref.read(userNameProvider.notifier).setName(v),
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      decoration: InputDecoration(
        labelText: 'Nome',
        hintText: 'Come ti chiami?',
        helperText: 'Usato per il saluto in Home',
        helperStyle: TextStyle(color: t.faint),
        prefixIcon: Icon(Icons.person_outline, color: t.dim),
        border: InputBorder.none,
        focusedBorder: InputBorder.none,
        enabledBorder: InputBorder.none,
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: t.primary, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle, style: text.bodySmall?.copyWith(color: t.faint)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final bool showDivider;

  const _TimeRow({
    required this.label,
    required this.onTap,
    required this.onDelete,
    required this.showDivider,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(Icons.alarm, color: t.dim, size: 22),
                const SizedBox(width: 14),
                Expanded(child: Text(label, style: text.titleMedium)),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  color: t.faint,
                  tooltip: 'Rimuovi',
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
        if (showDivider) Divider(height: 1, color: t.line),
      ],
    );
  }
}

class _DeviceCard extends ConsumerWidget {
  const _DeviceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final source = ref.watch(heartRateSourceProvider);
    final readiness = ref.watch(watchReadinessProvider);

    final color = switch (readiness) {
      WatchReadiness.ready => t.primary,
      WatchReadiness.error || WatchReadiness.bluetoothOff => t.alert,
      _ => t.faint,
    };

    final Widget trailing;
    if (readiness == WatchReadiness.connecting) {
      trailing = const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (readiness == WatchReadiness.bluetoothOff) {
      trailing = FilledButton.tonal(onPressed: requestEnableBluetooth, child: const Text('Attiva BT'));
    } else if (readiness.isReady) {
      trailing = TextButton(onPressed: () => source.reconnect(), child: const Text('Riconnetti'));
    } else {
      trailing = FilledButton.tonal(
        onPressed: () => source.reconnect(),
        child: Text(readiness == WatchReadiness.noDevice ? 'Cerca orologio' : 'Connetti'),
      );
    }

    return AppCard(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
            child: Icon(Icons.watch_outlined, color: color, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(source.displayName, style: text.titleMedium),
                const SizedBox(height: 2),
                Text(readiness.title, style: text.bodySmall?.copyWith(color: t.dim)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}

/// Sezione "Statistiche d'uso (locali)" (#13): mostra le metriche raccolte
/// on-device. Nessun dato lascia il telefono.
class _UsageStatsCard extends ConsumerWidget {
  const _UsageStatsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final s = ref.watch(usageSummaryProvider);
    final w = ref.watch(watchlessShareProvider).valueOrNull;

    String ttfb() {
      final d = s.timeToFirstBreath;
      if (d == null) return '—';
      return d.inMinutes < 1 ? '${d.inSeconds}s' : '${d.inMinutes} min';
    }

    String watchless() {
      if (w == null || w.total == 0) return '—';
      final pct = (100 * w.watchless / w.total).round();
      return '$pct% (${w.watchless}/${w.total})';
    }

    final streak =
        s.currentStreak == 1 ? '1 giorno' : '${s.currentStreak} giorni';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          child: Column(
            children: [
              _StatRow(label: 'Giorni attivi', value: '${s.activeDays}'),
              _StatRow(label: 'Serie attuale', value: streak),
              _StatRow(label: 'Primo respiro dopo l\'avvio', value: ttfb()),
              _StatRow(label: 'Respiri senza orologio', value: watchless()),
              _StatRow(
                  label: 'Tornato il giorno dopo',
                  value: s.returnedD1 ? 'Sì' : 'No'),
              _StatRow(
                  label: 'Tornato entro 7 giorni',
                  value: s.returnedD7 ? 'Sì' : 'No'),
              _StatRow(
                label: 'Onboarding completato',
                value: s.onboardingCompleted ? 'Sì' : 'No',
                showDivider: false,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Tutto in locale: nessun dato lascia il telefono.',
          style: text.bodySmall?.copyWith(color: t.faint),
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  final bool showDivider;
  const _StatRow({
    required this.label,
    required this.value,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Expanded(child: Text(label, style: text.bodyMedium)),
              Text(
                value,
                style: text.bodyMedium?.copyWith(
                  color: t.dim,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (showDivider) Divider(height: 1, color: t.line),
      ],
    );
  }
}
