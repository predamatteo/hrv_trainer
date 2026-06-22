import 'package:flutter/material.dart';

/// Token semantici dell'app: l'intera tavolozza del mockup Material 3 esposta
/// come `ThemeExtension`, così le schermate leggono `context.tokens.warn`
/// invece di incollare esadecimali. Affianca il [ColorScheme] (vedi
/// `app_theme.dart`): i ruoli Material standard restano on-brand per i widget
/// generici, mentre i bisogni su misura (warn/good/alert, inhale/exhale,
/// superfici tonali, griglie dei grafici) vivono qui.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  /// Sfondo dello scaffold: tinta calma sotto le superfici.
  final Color screenBg;

  /// Superficie delle card: contrasto netto col [screenBg].
  final Color surface;

  /// Superficie tonale per elementi secondari (chip, tile, sfondi morbidi).
  final Color tonal;

  /// Variante tonale più marcata (barre inattive, riempimenti).
  final Color tonal2;

  /// Testo primario ad alto contrasto.
  final Color text;

  /// Testo attenuato per descrizioni e sottotitoli.
  final Color dim;

  /// Testo flebile per didascalie, unità di misura, label minime.
  final Color faint;

  /// Colore brand: petrolio profondo (azioni, accenti).
  final Color primary;

  /// Contenuto su [primary].
  final Color onPrimary;

  /// Container tonale del brand: superfici evidenziate calme.
  final Color primaryTonal;

  /// Accento verde muschio (richiamo naturale/atletico).
  final Color accent;

  /// Container tonale dell'accento.
  final Color accentTonal;

  /// Fase inspiratoria dell'orb: teal chiaro.
  final Color inhale;

  /// Fase espiratoria dell'orb: verde-turchese profondo.
  final Color exhale;

  /// Linee/divisori sottili (bordi delle card, separatori).
  final Color line;

  /// Stato positivo (prontezza alta, coerenza buona).
  final Color good;

  /// Stato di attenzione.
  final Color warn;

  /// Stato critico / errore.
  final Color alert;

  /// Sfondo tonale per lo stato positivo.
  final Color goodTonal;

  /// Sfondo tonale per l'attenzione.
  final Color warnTonal;

  /// Sfondo tonale per lo stato critico.
  final Color alertTonal;

  /// Linee della griglia dei grafici.
  final Color grid;

  const AppTokens({
    required this.screenBg,
    required this.surface,
    required this.tonal,
    required this.tonal2,
    required this.text,
    required this.dim,
    required this.faint,
    required this.primary,
    required this.onPrimary,
    required this.primaryTonal,
    required this.accent,
    required this.accentTonal,
    required this.inhale,
    required this.exhale,
    required this.line,
    required this.good,
    required this.warn,
    required this.alert,
    required this.goodTonal,
    required this.warnTonal,
    required this.alertTonal,
    required this.grid,
  });

  /// Tema chiaro: sfondi off-white verdognoli, accenti petrolio.
  static const AppTokens light = AppTokens(
    screenBg: Color(0xFFEDF3F1),
    surface: Color(0xFFFFFFFF),
    tonal: Color(0xFFE3EDEA),
    tonal2: Color(0xFFD6E3DF),
    text: Color(0xFF102A2D),
    dim: Color(0xFF4E6562),
    faint: Color(0xFF849A96),
    primary: Color(0xFF0F6F7A),
    onPrimary: Color(0xFFFFFFFF),
    primaryTonal: Color(0xFFCFE6E6),
    accent: Color(0xFF5E8050),
    accentTonal: Color(0xFFDCE7D2),
    inhale: Color(0xFF4FB3BF),
    exhale: Color(0xFF14695E),
    line: Color(0xFFDCE7E3),
    good: Color(0xFF5E8C52),
    warn: Color(0xFFB0791F),
    alert: Color(0xFFBF5C49),
    goodTonal: Color(0xFFDEE9D4),
    warnTonal: Color(0xFFF1E5CB),
    alertTonal: Color(0xFFF2DAD2),
    grid: Color(0xFFE6EEEB),
  );

  /// Tema scuro: notturno profondo, accenti luminosi per il contrasto AA.
  static const AppTokens dark = AppTokens(
    screenBg: Color(0xFF07151A),
    surface: Color(0xFF0E2227),
    tonal: Color(0xFF13292F),
    tonal2: Color(0xFF1C383F),
    text: Color(0xFFE8F0EE),
    dim: Color(0xFF9CB2AF),
    faint: Color(0xFF6B8480),
    primary: Color(0xFF54B9C4),
    onPrimary: Color(0xFF04222A),
    primaryTonal: Color(0xFF123A40),
    accent: Color(0xFF90B17D),
    accentTonal: Color(0xFF1E3326),
    inhale: Color(0xFF66C6D1),
    exhale: Color(0xFF2E8C7E),
    line: Color(0xFF21383D),
    good: Color(0xFF84AE72),
    warn: Color(0xFFD9A441),
    alert: Color(0xFFD88067),
    goodTonal: Color(0xFF1C3325),
    warnTonal: Color(0xFF332C16),
    alertTonal: Color(0xFF33211A),
    grid: Color(0xFF1A2F34),
  );

  @override
  AppTokens copyWith({
    Color? screenBg,
    Color? surface,
    Color? tonal,
    Color? tonal2,
    Color? text,
    Color? dim,
    Color? faint,
    Color? primary,
    Color? onPrimary,
    Color? primaryTonal,
    Color? accent,
    Color? accentTonal,
    Color? inhale,
    Color? exhale,
    Color? line,
    Color? good,
    Color? warn,
    Color? alert,
    Color? goodTonal,
    Color? warnTonal,
    Color? alertTonal,
    Color? grid,
  }) {
    return AppTokens(
      screenBg: screenBg ?? this.screenBg,
      surface: surface ?? this.surface,
      tonal: tonal ?? this.tonal,
      tonal2: tonal2 ?? this.tonal2,
      text: text ?? this.text,
      dim: dim ?? this.dim,
      faint: faint ?? this.faint,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      primaryTonal: primaryTonal ?? this.primaryTonal,
      accent: accent ?? this.accent,
      accentTonal: accentTonal ?? this.accentTonal,
      inhale: inhale ?? this.inhale,
      exhale: exhale ?? this.exhale,
      line: line ?? this.line,
      good: good ?? this.good,
      warn: warn ?? this.warn,
      alert: alert ?? this.alert,
      goodTonal: goodTonal ?? this.goodTonal,
      warnTonal: warnTonal ?? this.warnTonal,
      alertTonal: alertTonal ?? this.alertTonal,
      grid: grid ?? this.grid,
    );
  }

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(
      screenBg: Color.lerp(screenBg, other.screenBg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      tonal: Color.lerp(tonal, other.tonal, t)!,
      tonal2: Color.lerp(tonal2, other.tonal2, t)!,
      text: Color.lerp(text, other.text, t)!,
      dim: Color.lerp(dim, other.dim, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      primaryTonal: Color.lerp(primaryTonal, other.primaryTonal, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentTonal: Color.lerp(accentTonal, other.accentTonal, t)!,
      inhale: Color.lerp(inhale, other.inhale, t)!,
      exhale: Color.lerp(exhale, other.exhale, t)!,
      line: Color.lerp(line, other.line, t)!,
      good: Color.lerp(good, other.good, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      alert: Color.lerp(alert, other.alert, t)!,
      goodTonal: Color.lerp(goodTonal, other.goodTonal, t)!,
      warnTonal: Color.lerp(warnTonal, other.warnTonal, t)!,
      alertTonal: Color.lerp(alertTonal, other.alertTonal, t)!,
      grid: Color.lerp(grid, other.grid, t)!,
    );
  }
}

/// Accesso ergonomico ai token: `context.tokens.warn`.
extension AppTokensContext on BuildContext {
  AppTokens get tokens => Theme.of(this).extension<AppTokens>()!;
}
