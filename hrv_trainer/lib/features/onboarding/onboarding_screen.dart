import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/notifications/reminder_settings.dart';
import '../../shared/profile/onboarding_provider.dart';
import '../../shared/ui/ui.dart';
import '../pacer/state/pacer_controller.dart';
import '../pacer/widgets/breathing_orb.dart';

/// Onboarding di prima apertura. Poche schermate calme che spiegano l'idea
/// d'uso ("allena la calma, segui il cerchio, non un numero"), un primo respiro
/// guidato di **1 minuto** senza orologio né permessi (l'aha-moment subito), e
/// un opt-in finale soft per il promemoria del mattino. Al termine marca
/// [onboardingSeenProvider] e va in Home. Vedi `docs/ux-and-usage.md` §4.
///
/// Usa uno step a indice (non un `PageView`) così il pacer dello step "respiro"
/// parte e si ferma esattamente quando quello step è montato/smontato.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _step = 0;
  bool _finishing = false;

  /// Schermate informative (intro + educazione + aspettative oneste). Lo step
  /// "respiro" e l'opt-in permessi sono speciali e vengono dopo queste.
  static const List<_InfoPage> _infoPages = [
    _InfoPage(
      icon: Icons.self_improvement,
      title: 'Allena la calma',
      lead:
          'Pochi minuti di respiro guidato al giorno per ritrovare la calma. '
          'Segui il cerchio, non un numero.',
    ),
    _InfoPage(
      icon: Icons.favorite_outline,
      title: 'Come funziona',
      bullets: [
        'Non stai misurando la tua salute: alleni la calma.',
        'Respirando lento il cuore inizia a oscillare più ampio, e questo '
            'calma il sistema nervoso.',
      ],
    ),
    _InfoPage(
      icon: Icons.blur_circular,
      title: 'Il cerchio e l’orologio',
      bullets: [
        'Inspira mentre il cerchio cresce, espira mentre cala. Segui il suo '
            'ritmo — o chiudi gli occhi e senti la vibrazione.',
        'Se hai un Garmin, conferma in silenzio che il corpo risponde e tiene '
            'la storia dei tuoi progressi. Ma il respiro funziona benissimo '
            'anche senza.',
      ],
    ),
    _InfoPage(
      icon: Icons.spa_outlined,
      title: 'Cosa aspettarti',
      bullets: [
        'La calma arriva subito; i miglioramenti stabili maturano in '
            'settimane di pratica costante.',
        'Non è un dispositivo medico e non sostituisce un parere clinico.',
        'Se durante il respiro senti capogiri, fermati e torna a respirare '
            'normale.',
      ],
    ),
  ];

  int get _breathStep => _infoPages.length;
  int get _permsStep => _infoPages.length + 1;
  int get _lastStep => _permsStep;

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    await ref.read(onboardingSeenProvider.notifier).markSeen();
    if (mounted) context.go('/');
  }

  void _next() {
    if (_step >= _lastStep) {
      _finish();
    } else {
      setState(() => _step++);
    }
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.screenBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              _OnboardingHeader(
                steps: _lastStep + 1,
                current: _step,
                // L'ultimo step ha già il suo "Inizia": niente Salta lì.
                onSkip: _step == _lastStep ? null : _finish,
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: _buildStep(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep() {
    if (_step < _infoPages.length) {
      return _InfoStepView(
        key: ValueKey('info_$_step'),
        page: _infoPages[_step],
        onPrimary: _next,
        onBack: _step > 0 ? _back : null,
      );
    }
    if (_step == _breathStep) {
      // onDone (60s trascorsi) e onSkip avanzano entrambi: la differenza è solo
      // semantica per l'utente.
      return _BreathStepView(key: const ValueKey('breath'), onDone: _next, onSkip: _next);
    }
    return _PermissionsStepView(key: const ValueKey('perms'), onDone: _finish);
  }
}

// ---------------------------------------------------------------------------
// Header: puntini di progresso + "Salta".
// ---------------------------------------------------------------------------

class _OnboardingHeader extends StatelessWidget {
  final int steps;
  final int current;
  final VoidCallback? onSkip;
  const _OnboardingHeader({required this.steps, required this.current, this.onSkip});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          for (var i = 0; i < steps; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.only(right: 6),
              width: i == current ? 22 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i == current ? t.primary : t.tonal2,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          const Spacer(),
          if (onSkip != null)
            TextButton(
              onPressed: onSkip,
              child: Text('Salta', style: TextStyle(color: t.dim)),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step informativo (intro / educazione / aspettative).
// ---------------------------------------------------------------------------

class _InfoPage {
  final IconData icon;
  final String title;
  final String? lead;
  final List<String> bullets;
  const _InfoPage({
    required this.icon,
    required this.title,
    this.lead,
    this.bullets = const [],
  });
}

class _InfoStepView extends StatelessWidget {
  final _InfoPage page;
  final VoidCallback onPrimary;
  final VoidCallback? onBack;
  const _InfoStepView({super.key, required this.page, required this.onPrimary, this.onBack});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(color: t.primaryTonal, shape: BoxShape.circle),
                  child: Icon(page.icon, size: 38, color: t.primary),
                ),
                const SizedBox(height: 28),
                Text(page.title, style: text.headlineSmall),
                if (page.lead != null) ...[
                  const SizedBox(height: 14),
                  Text(page.lead!, style: text.titleMedium?.copyWith(color: t.dim, height: 1.4)),
                ],
                if (page.bullets.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  for (final b in page.bullets) _Bullet(b),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (onBack != null)
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                color: t.dim,
                tooltip: 'Indietro',
              ),
            Expanded(
              child: FilledButton(
                onPressed: onPrimary,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  backgroundColor: t.primary,
                  foregroundColor: t.onPrimary,
                ),
                child: const Text('Avanti'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(color: t.text, height: 1.4);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.check_circle_outline, size: 20, color: t.primary),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step "respiro 1 minuto": riusa l'orb + pacerController. Nessun orologio,
// nessun permesso. Si avvia entrando, si ferma uscendo (lifecycle del widget).
// ---------------------------------------------------------------------------

class _BreathStepView extends ConsumerStatefulWidget {
  final VoidCallback onDone;
  final VoidCallback onSkip;
  const _BreathStepView({super.key, required this.onDone, required this.onSkip});

  @override
  ConsumerState<_BreathStepView> createState() => _BreathStepViewState();
}

class _BreathStepViewState extends ConsumerState<_BreathStepView> {
  static const int _targetSec = 60;
  Timer? _ticker;
  int _remaining = _targetSec;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(pacerControllerProvider.notifier).start();
    });
    // Countdown a parete (1 Hz): l'orb anima dal tick del pacer, il conto alla
    // rovescia e il completamento li gestiamo qui, indipendenti dalle pause.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remaining--);
      if (_remaining <= 0) {
        _ticker?.cancel();
        widget.onDone();
      }
    });
  }

  @override
  void dispose() {
    // Controller non-autoDispose e condiviso: va fermato a mano uscendo,
    // altrimenti Timer (e vibrazioni) continuerebbero in background.
    ref.read(pacerControllerProvider.notifier).pause();
    WakelockPlus.disable();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final orbSize = (MediaQuery.sizeOf(context).width - 130).clamp(180.0, 240.0);
    return Column(
      children: [
        const SizedBox(height: 12),
        Text('Proviamo subito', style: text.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Un minuto di respiro. Segui il cerchio — o chiudi gli occhi e '
          'senti la vibrazione.',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: t.dim, height: 1.4),
        ),
        const Spacer(),
        _OnbOrb(size: orbSize),
        const SizedBox(height: 26),
        Text('${_remaining}s', style: text.displaySmall),
        const Spacer(),
        TextButton(
          onPressed: widget.onSkip,
          child: Text('Salta il respiro', style: TextStyle(color: t.dim)),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// Solo l'orb osserva il tick a 20 Hz: isolarlo evita di ricostruire il resto
/// dello step a ogni frame (stesso pattern di `_OrbView` in pacer_screen.dart).
class _OnbOrb extends ConsumerWidget {
  final double size;
  const _OnbOrb({required this.size});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final tick = ref.watch(pacerControllerProvider);
    return BreathingOrb(
      amplitude: tick.amplitude,
      phase: tick.phase,
      phaseProgress: tick.progress,
      size: size,
      inhaleColor: t.inhale,
      exhaleColor: t.exhale,
    );
  }
}

// ---------------------------------------------------------------------------
// Step finale: opt-in soft del promemoria del mattino. È il primo momento in
// cui chiediamo permessi (notifiche), DOPO il respiro. Il Garmin si collega
// più avanti, contestualmente (lo gestisce il watch readiness gate).
// ---------------------------------------------------------------------------

class _PermissionsStepView extends ConsumerStatefulWidget {
  final VoidCallback onDone;
  const _PermissionsStepView({super.key, required this.onDone});

  @override
  ConsumerState<_PermissionsStepView> createState() => _PermissionsStepViewState();
}

class _PermissionsStepViewState extends ConsumerState<_PermissionsStepView> {
  bool _reminderOn = false;
  bool _busy = false;

  Future<void> _setReminder(bool value) async {
    setState(() => _busy = true);
    final ctrl = ref.read(reminderControllerProvider.notifier);
    var on = false;
    if (value) {
      // enable() chiede il permesso notifiche (Android 13+) e ritorna false se
      // negato: in quel caso lo switch resta spento.
      final granted = await ctrl.enable();
      if (granted) {
        await ctrl.applyPreset([ReminderPresets.morning]);
        on = true;
      }
    } else {
      await ctrl.disable();
    }
    if (mounted) {
      setState(() {
        _reminderOn = on;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(color: t.primaryTonal, shape: BoxShape.circle),
                  child: Icon(Icons.notifications_none, size: 38, color: t.primary),
                ),
                const SizedBox(height: 28),
                Text('Quasi pronto', style: text.headlineSmall),
                const SizedBox(height: 14),
                Text(
                  'Un invito gentile a respirare, una volta al giorno. Niente '
                  'allarmi: solo un promemoria che puoi togliere quando vuoi.',
                  style: text.titleMedium?.copyWith(color: t.dim, height: 1.4),
                ),
                const SizedBox(height: 22),
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.wb_twilight, size: 22, color: t.primary),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Promemoria del mattino', style: text.bodyLarge),
                            Text('Un invito alle 8:00', style: text.bodySmall?.copyWith(color: t.dim)),
                          ],
                        ),
                      ),
                      Switch(
                        value: _reminderOn,
                        onChanged: _busy ? null : (v) => _setReminder(v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.watch_outlined, size: 20, color: t.dim),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Hai un Garmin? Lo colleghi quando vuoi: l’app te lo '
                        'chiederà al momento giusto. Per ora basta il respiro.',
                        style: text.bodyMedium?.copyWith(color: t.dim, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: widget.onDone,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(54),
            backgroundColor: t.primary,
            foregroundColor: t.onPrimary,
          ),
          child: const Text('Inizia'),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
