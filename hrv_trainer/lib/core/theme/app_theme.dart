import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// Factory dei temi Material 3 chiaro/scuro, costruiti dai token semantici
/// in [AppTokens]. Strategia a doppio binario:
///  - il [ColorScheme] viene "pinnato" sui token così i widget Material
///    generici (Card, Chip, FilledButton, NavigationBar…) restano on-brand
///    senza toccare ogni schermata;
///  - i bisogni su misura (good/warn/alert, inhale/exhale, griglie) si leggono
///    da `context.tokens`.
class AppTheme {
  AppTheme._();

  /// TextTheme su Figtree. Cifre tabellari sugli stili numerici (countdown,
  /// bpm, RMSSD, z-score) per allineare le colonne di numeri.
  static TextTheme _textTheme(Color onSurface) {
    const tabular = <FontFeature>[FontFeature.tabularFigures()];
    TextStyle s(
      double size,
      FontWeight weight, {
      double? height,
      double? spacing,
      bool tab = false,
    }) {
      return TextStyle(
        fontFamily: 'Figtree',
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: spacing,
        color: onSurface,
        fontFeatures: tab ? tabular : null,
      );
    }

    return TextTheme(
      displayLarge: s(44, FontWeight.w700, spacing: -0.5, tab: true),
      displayMedium: s(40, FontWeight.w700, spacing: -0.25, tab: true),
      displaySmall: s(32, FontWeight.w600, tab: true),
      headlineLarge: s(28, FontWeight.w700, tab: true),
      headlineMedium: s(25, FontWeight.w600, spacing: -0.2, tab: true),
      headlineSmall: s(24, FontWeight.w700, spacing: -0.2, tab: true),
      titleLarge: s(22, FontWeight.w600, spacing: -0.1, tab: true),
      titleMedium: s(17, FontWeight.w600, tab: true),
      titleSmall: s(14, FontWeight.w600, spacing: 0.1, tab: true),
      bodyLarge: s(16, FontWeight.w400, height: 1.5, spacing: 0.1),
      bodyMedium: s(14, FontWeight.w400, height: 1.45, spacing: 0.1),
      bodySmall: s(12.5, FontWeight.w400, height: 1.4, spacing: 0.2),
      labelLarge: s(14, FontWeight.w600, spacing: 0.1, tab: true),
      labelMedium: s(12, FontWeight.w600, spacing: 0.3, tab: true),
      labelSmall: s(11, FontWeight.w500, spacing: 0.4, tab: true),
    );
  }

  static ThemeData _build(AppTokens t, Brightness brightness) {
    // Seed dal petrolio per armonia Material 3, poi pin dei ruoli portanti
    // sui token così l'identità resta esatta e non "derivata".
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: t.primary,
      brightness: brightness,
    ).copyWith(
      primary: t.primary,
      onPrimary: t.onPrimary,
      primaryContainer: t.primaryTonal,
      onPrimaryContainer: t.primary,
      secondary: t.accent,
      onSecondary: t.onPrimary,
      secondaryContainer: t.accentTonal,
      onSecondaryContainer: t.accent,
      surface: t.surface,
      onSurface: t.text,
      onSurfaceVariant: t.dim,
      surfaceContainerLowest: t.surface,
      surfaceContainerLow: t.tonal,
      surfaceContainer: t.tonal,
      surfaceContainerHigh: t.tonal,
      surfaceContainerHighest: t.tonal2,
      outline: t.faint,
      outlineVariant: t.line,
      error: t.alert,
      onError: t.onPrimary,
      surfaceTint: Colors.transparent,
    );

    final textTheme = _textTheme(t.text);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.screenBg,
      fontFamily: 'Figtree',
      textTheme: textTheme,
      extensions: <ThemeExtension<dynamic>>[t],
      iconTheme: IconThemeData(color: t.dim),

      // AppBar piatta, fusa con lo scaffold (le schermate usano header espliciti).
      appBarTheme: AppBarTheme(
        backgroundColor: t.screenBg,
        foregroundColor: t.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
        iconTheme: IconThemeData(color: t.text),
      ),

      // Card bordata: superficie piena + 1px di linea, raggio ampio.
      cardTheme: CardThemeData(
        color: t.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: t.line, width: 1),
        ),
      ),

      // Chip stadio su superficie tonale; selezione su primary-tonal.
      chipTheme: ChipThemeData(
        backgroundColor: t.tonal,
        selectedColor: t.primaryTonal,
        secondarySelectedColor: t.primaryTonal,
        checkmarkColor: t.primary,
        disabledColor: t.tonal,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        labelStyle: textTheme.labelLarge?.copyWith(color: t.dim),
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(color: t.primary),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        showCheckmark: false,
      ),

      // Bottoni pieni grandi e rotondi, ottimi come target touch in sessione.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.primary,
          foregroundColor: t.onPrimary,
          minimumSize: const Size(64, 54),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: textTheme.labelLarge?.copyWith(fontSize: 15),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.text,
          minimumSize: const Size(64, 54),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
          side: BorderSide(color: t.line, width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: textTheme.labelLarge?.copyWith(fontSize: 15),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.dim,
          textStyle: textTheme.labelLarge,
        ),
      ),

      // NavigationBar con pillola primary-tonal sotto l'icona attiva.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: t.primaryTonal,
        indicatorShape: const StadiumBorder(),
        height: 66,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(size: 24, color: selected ? t.primary : t.faint);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelSmall?.copyWith(
            color: selected ? t.primary : t.faint,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          );
        }),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : t.faint),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? t.primary : t.tonal2),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: t.primary,
        inactiveTrackColor: t.tonal2,
        thumbColor: t.primary,
        overlayColor: t.primary.withValues(alpha: 0.12),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.primary,
        linearTrackColor: t.tonal2,
        circularTrackColor: t.tonal2,
      ),

      dividerTheme: DividerThemeData(color: t.line, thickness: 1, space: 1),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.text,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: t.surface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
    );
  }

  /// Tema chiaro: sfondi off-white verdognoli, accenti petrolio.
  static ThemeData light() => _build(AppTokens.light, Brightness.light);

  /// Tema scuro: notturno profondo per sessioni serali.
  static ThemeData dark() => _build(AppTokens.dark, Brightness.dark);
}
