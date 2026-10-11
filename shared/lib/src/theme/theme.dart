import 'package:flutter/material.dart';

import '../protocol/settings.dart';

/// Ol1nPlay look: near-black surfaces, one warm accent (amber like a tube
/// glow), monospace for everything technical so numbers line up.
abstract final class Ol1nTheme {
  static const accent = Color(0xFFE8A33D);
  static const accentDim = Color(0xFF9A6A22);
  static const bitPerfectGreen = Color(0xFF4CCB7A);
  static const warnAmber = Color(0xFFE8A33D);
  static const errorRed = Color(0xFFE05A4F);

  static const _darkBg = Color(0xFF0B0B0D);
  static const _darkSurface = Color(0xFF131316);
  static const _darkSurfaceHi = Color(0xFF1C1C21);
  static const _darkOutline = Color(0xFF2A2A31);
  static const _darkText = Color(0xFFEDEBE6);
  static const _darkTextDim = Color(0xFF8E8C88);

  // "Black": true-black background and a notch less contrast everywhere,
  // for a dark room and OLED panels.
  static const _blackBg = Color(0xFF000000);
  static const _blackSurface = Color(0xFF070708);
  static const _blackSurfaceHi = Color(0xFF111114);
  static const _blackOutline = Color(0xFF1C1C21);
  static const _blackText = Color(0xFFCFCDC8);
  static const _blackTextDim = Color(0xFF6F6D69);

  static const _lightBg = Color(0xFFF7F5F0);
  static const _lightSurface = Color(0xFFFFFFFF);
  static const _lightSurfaceHi = Color(0xFFEFECE5);
  static const _lightOutline = Color(0xFFD8D4CB);
  static const _lightText = Color(0xFF1A1917);
  static const _lightTextDim = Color(0xFF6E6B65);

  /// Font family for technical readouts (sample rates, counters, times).
  static const monoFamily = 'monospace';

  /// Text style for technical readouts.
  static TextStyle mono(
    BuildContext context, {
    double? size,
    Color? color,
    FontWeight? weight,
  }) => TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: const [
      'Menlo',
      'Consolas',
      'Roboto Mono',
      'Courier New',
    ],
    fontSize: size,
    color: color ?? Theme.of(context).colorScheme.onSurface,
    fontWeight: weight,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    bg: _darkBg,
    surface: _darkSurface,
    surfaceHi: _darkSurfaceHi,
    outline: _darkOutline,
    text: _darkText,
    textDim: _darkTextDim,
  );

  static ThemeData black() => _build(
    brightness: Brightness.dark,
    bg: _blackBg,
    surface: _blackSurface,
    surfaceHi: _blackSurfaceHi,
    outline: _blackOutline,
    text: _blackText,
    textDim: _blackTextDim,
  );

  static ThemeData light() => _build(
    brightness: Brightness.light,
    bg: _lightBg,
    surface: _lightSurface,
    surfaceHi: _lightSurfaceHi,
    outline: _lightOutline,
    text: _lightText,
    textDim: _lightTextDim,
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color surfaceHi,
    required Color outline,
    required Color text,
    required Color textDim,
  }) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: const Color(0xFF1A1200),
      primaryContainer: dark ? accentDim : const Color(0xFFFFE2B3),
      onPrimaryContainer: dark
          ? const Color(0xFFFFE9C4)
          : const Color(0xFF3A2600),
      secondary: textDim,
      onSecondary: bg,
      secondaryContainer: surfaceHi,
      onSecondaryContainer: text,
      tertiary: bitPerfectGreen,
      onTertiary: const Color(0xFF002911),
      error: errorRed,
      onError: Colors.white,
      surface: surface,
      onSurface: text,
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceHi,
      surfaceContainerHighest: surfaceHi,
      onSurfaceVariant: textDim,
      outline: outline,
      outlineVariant: outline,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: text,
      onInverseSurface: bg,
      inversePrimary: accentDim,
      surfaceTint: Colors.transparent,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
    );
    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: outline),
        ),
      ),
      dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
      listTileTheme: ListTileThemeData(
        dense: true,
        selectedColor: accent,
        selectedTileColor: accent.withValues(alpha: 0.08),
        iconColor: textDim,
        textColor: text,
      ),
      iconTheme: IconThemeData(color: textDim),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: outline,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.15),
        trackHeight: 3,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : textDim,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentDim : surfaceHi,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceHi,
        side: BorderSide(color: outline),
        labelStyle: TextStyle(color: text, fontSize: 12),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: surfaceHi,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(color: text, fontSize: 12),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceHi,
        contentTextStyle: TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
      ),
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
    );
  }

  /// Resolves `Settings.theme` ("system" | "dark" | "black" | "light").
  static ThemeMode modeOf(String theme) => switch (theme) {
    'dark' || 'black' => ThemeMode.dark,
    'light' => ThemeMode.light,
    _ => ThemeMode.system,
  };

  static ThemeMode modeOfSettings(Settings? s) => modeOf(s?.theme ?? 'system');

  /// The dark theme `Settings.theme` asks for: "black" or the regular one.
  static ThemeData darkOfSettings(Settings? s) =>
      s?.theme == 'black' ? black() : dark();
}
