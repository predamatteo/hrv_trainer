import 'package:flutter/material.dart';

/// Palette cromatica dell'app HRV Trainer: toni calmi ma clinici.
class AppColors {
  AppColors._();

  // Seed primario: petrolio profondo, evoca respiro e stabilita'.
  static const Color primary = Color(0xFF0F6F7A);
  // Container primario: petrolio desaturato per superfici tonali.
  static const Color primaryContainer = Color(0xFFBCE4E8);
  // Secondario: verde muschio caldo, richiamo naturale e atletico.
  static const Color secondary = Color(0xFF6B8F5A);
  // Tinta di superficie per elevazioni Material 3.
  static const Color surfaceTint = Color(0xFF0F6F7A);

  // Fase inspiratoria: teal chiaro, leggerezza e apertura.
  static const Color inhale = Color(0xFF4FB3BF);
  // Fase espiratoria: verde-turchese profondo, rilascio e radicamento.
  static const Color exhale = Color(0xFF14695E);

  // Stati semantici: chiarezza clinica senza saturazioni aggressive.
  static const Color success = Color(0xFF2E7D5B);
  static const Color warning = Color(0xFFB8791F);
  static const Color error = Color(0xFFB3261E);

  // Varianti dark: desaturate e luminose per contrasto AA su sfondo scuro.
  static const Color primaryDark = Color(0xFF5FD3DE);
  static const Color primaryContainerDark = Color(0xFF004E56);
  static const Color secondaryDark = Color(0xFFA7C896);
  static const Color surfaceTintDark = Color(0xFF5FD3DE);

  // Fasi respiratorie in dark: piu' luminose per leggibilita'.
  static const Color inhaleDark = Color(0xFF7FD4DE);
  static const Color exhaleDark = Color(0xFF4FB8A5);

  // Stati semantici dark.
  static const Color successDark = Color(0xFF6BBF94);
  static const Color warningDark = Color(0xFFE3B56A);
  static const Color errorDark = Color(0xFFF2B8B5);
}

/// Factory dei temi Material 3 per modalita' chiara e scura.
class AppTheme {
  AppTheme._();

  // TextTheme condiviso: usa font di sistema (San Francisco / Roboto).
  static TextTheme _buildTextTheme(Color onSurface) {
    return TextTheme(
      displayLarge: TextStyle(fontSize: 57, fontWeight: FontWeight.w300, letterSpacing: -0.5, color: onSurface),
      displayMedium: TextStyle(fontSize: 45, fontWeight: FontWeight.w300, color: onSurface),
      displaySmall: TextStyle(fontSize: 36, fontWeight: FontWeight.w400, color: onSurface),
      headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w500, color: onSurface),
      headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w500, color: onSurface),
      headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w500, color: onSurface),
      titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: onSurface),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.15, color: onSurface),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.1, color: onSurface),
      bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, letterSpacing: 0.5, height: 1.5, color: onSurface),
      bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, letterSpacing: 0.25, height: 1.45, color: onSurface),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, letterSpacing: 0.4, color: onSurface),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.1, color: onSurface),
      labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: onSurface),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: onSurface),
    );
  }

  /// Tema chiaro: sfondi off-white, contrasti morbidi, accenti petrolio.
  static ThemeData light() {
    // ColorScheme generato dal seed petrolio per armonia Material 3.
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
      primary: AppColors.primary,
      secondary: AppColors.secondary,
      error: AppColors.error,
      surfaceTint: AppColors.surfaceTint,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF7F9F9),
      textTheme: _buildTextTheme(scheme.onSurface),

      // AppBar piatta, centrata, con tono superficie per minimalismo clinico.
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: true,
        titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: scheme.onSurface),
      ),

      // Card con bordi morbidi e superficie tonale per profondita' calma.
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: const EdgeInsets.all(8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),

      // FilledButton grande e rotondo, ottimo per target touch durante sessioni.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        ),
      ),

      // Divisori impercettibili per non affaticare la vista in biofeedback.
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
    );
  }

  /// Tema scuro: ideale per sessioni serali e modalita' notturna da atleta.
  static ThemeData dark() {
    // ColorScheme scuro derivato dallo stesso seed per coerenza visiva.
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.dark,
      primary: AppColors.primaryDark,
      secondary: AppColors.secondaryDark,
      error: AppColors.errorDark,
      surfaceTint: AppColors.surfaceTintDark,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0E1515),
      textTheme: _buildTextTheme(scheme.onSurface),

      // AppBar scura senza elevazione per continuita' con scaffold.
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: true,
        titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: scheme.onSurface),
      ),

      // Card con superficie elevata tonale: profondita' senza bagliori.
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerHigh,
        elevation: 0,
        margin: const EdgeInsets.all(8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),

      // FilledButton coerente con il tema chiaro per consistenza muscolare.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        ),
      ),

      // Divisori tenui per sessioni in ambienti poco illuminati.
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
    );
  }
}
