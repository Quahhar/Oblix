import 'package:flutter/material.dart';

/// The "Paper" design system: warm paper surfaces, terracotta accent, serif
/// titles (Source Serif 4) with grotesk UI text (Familjen Grotesk).
///
/// All screen code reads colors through [OblixColors.of] so light/dark is
/// decided in exactly one place (values taken from the design canvas's light
/// screens and HOME·DARK / EDITOR·DARK variants).
class OblixColors extends ThemeExtension<OblixColors> {
  final Color bg; // page background
  final Color surface; // cards, sheets
  final Color surfaceAlt; // icon squares, inactive chips
  final Color chip; // segmented track, skeleton blocks
  final Color ink; // primary text
  final Color body; // note body text (slightly softer than ink)
  final Color inkSecondary; // supporting text
  final Color inkMuted; // eyebrows, placeholders
  final Color inkFaint; // timestamps, counts
  final Color outline; // faint strokes (empty check circles)
  final Color hairline; // borders / separators
  final Color accent; // terracotta
  final Color accentDeep; // pressed/derived terracotta (#8F4222)
  final Color accentSoft; // terracotta wash backgrounds
  final Color onAccent; // text/icons on terracotta
  final Color danger; // destructive / overdue
  final Color avatarBg;
  final Color avatarInk;
  final Color scrim; // sheet backdrop

  const OblixColors({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.chip,
    required this.ink,
    required this.body,
    required this.inkSecondary,
    required this.inkMuted,
    required this.inkFaint,
    required this.outline,
    required this.hairline,
    required this.accent,
    required this.accentDeep,
    required this.accentSoft,
    required this.onAccent,
    required this.danger,
    required this.avatarBg,
    required this.avatarInk,
    required this.scrim,
  });

  static const light = OblixColors(
    bg: Color(0xFFF0EEE6),
    surface: Color(0xFFFAF9F5),
    surfaceAlt: Color(0xFFEDE9DD),
    chip: Color(0xFFE7E2D4),
    ink: Color(0xFF1F1E1B),
    body: Color(0xFF33312B),
    inkSecondary: Color(0xFF6E6A5E),
    inkMuted: Color(0xFF8C877A),
    inkFaint: Color(0xFFA39D8D),
    outline: Color(0xFFC9C2B0),
    hairline: Color(0x171F1E1B), // rgba(31,30,27,.09)
    accent: Color(0xFFB0562F),
    accentDeep: Color(0xFF8F4222),
    accentSoft: Color(0x1FB0562F), // rgba(176,86,47,.12)
    onAccent: Color(0xFFFAF9F5),
    danger: Color(0xFFC0392B),
    avatarBg: Color(0xFFDCD3C0),
    avatarInk: Color(0xFF5C5749),
    scrim: Color(0x611F1E1B), // rgba(31,30,27,.38)
  );

  static const dark = OblixColors(
    bg: Color(0xFF262624),
    surface: Color(0xFF30302E),
    surfaceAlt: Color(0xFF3A3935),
    chip: Color(0xFF3A3935),
    ink: Color(0xFFECEAE4),
    body: Color(0xFFDDDAD1),
    inkSecondary: Color(0xFFA6A196),
    inkMuted: Color(0xFF8C877A),
    inkFaint: Color(0xFF787366),
    outline: Color(0xFF57544C),
    hairline: Color(0x14ECEAE4), // rgba(236,234,228,.08)
    accent: Color(0xFFB0562F),
    accentDeep: Color(0xFFE89B7C),
    accentSoft: Color(0x2EB0562F),
    onAccent: Color(0xFFFAF9F5),
    danger: Color(0xFFD9584A),
    avatarBg: Color(0xFF4A473F),
    avatarInk: Color(0xFFCFC9BA),
    scrim: Color(0x8A16150F),
  );

  static OblixColors of(BuildContext context) =>
      Theme.of(context).extension<OblixColors>()!;

  @override
  OblixColors copyWith() => this;

  @override
  OblixColors lerp(ThemeExtension<OblixColors>? other, double t) {
    if (other is! OblixColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return OblixColors(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surfaceAlt: l(surfaceAlt, other.surfaceAlt),
      chip: l(chip, other.chip),
      ink: l(ink, other.ink),
      body: l(body, other.body),
      inkSecondary: l(inkSecondary, other.inkSecondary),
      inkMuted: l(inkMuted, other.inkMuted),
      inkFaint: l(inkFaint, other.inkFaint),
      outline: l(outline, other.outline),
      hairline: l(hairline, other.hairline),
      accent: l(accent, other.accent),
      accentDeep: l(accentDeep, other.accentDeep),
      accentSoft: l(accentSoft, other.accentSoft),
      onAccent: l(onAccent, other.onAccent),
      danger: l(danger, other.danger),
      avatarBg: l(avatarBg, other.avatarBg),
      avatarInk: l(avatarInk, other.avatarInk),
      scrim: l(scrim, other.scrim),
    );
  }
}

/// Type ramp. Serif = titles & note bodies; sans = everything else.
abstract final class OblixType {
  static const serif = 'SourceSerif4';
  static const sans = 'FamiljenGrotesk';

  /// Big page title ("Notes", "Tasks", "Settings").
  static TextStyle pageTitle(OblixColors c) => TextStyle(
        fontFamily: serif,
        fontSize: 32,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
        color: c.ink,
        height: 1.15,
      );

  /// Note title inside the editor.
  static TextStyle editorTitle(OblixColors c) => TextStyle(
        fontFamily: serif,
        fontSize: 27,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        color: c.ink,
        height: 1.2,
      );

  /// Card / list-row note title.
  static TextStyle cardTitle(OblixColors c) => TextStyle(
        fontFamily: serif,
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
        color: c.ink,
        height: 1.3,
      );

  /// Long-form note body.
  static TextStyle noteBody(OblixColors c) => TextStyle(
        fontFamily: serif,
        fontSize: 15,
        color: c.body,
        height: 1.72,
      );

  /// UPPERCASE section eyebrow ("PINNED", "TODAY").
  static TextStyle eyebrow(OblixColors c, {Color? color}) => TextStyle(
        fontFamily: sans,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.3,
        color: color ?? c.inkMuted,
      );

  /// Card snippet / supporting copy.
  static TextStyle snippet(OblixColors c) => TextStyle(
        fontFamily: sans,
        fontSize: 12,
        color: c.inkSecondary,
        height: 1.5,
      );

  /// Timestamps, counts, faint metadata.
  static TextStyle meta(OblixColors c) => TextStyle(
        fontFamily: sans,
        fontSize: 11,
        color: c.inkFaint,
      );

  /// Standard UI text (list rows, buttons provide their own).
  static TextStyle ui(OblixColors c,
          {double size = 14.5,
          FontWeight weight = FontWeight.w400,
          Color? color}) =>
      TextStyle(
        fontFamily: sans,
        fontSize: size,
        fontWeight: weight,
        color: color ?? c.ink,
      );
}

abstract final class OblixTheme {
  static ThemeData _base(OblixColors c, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: c.accent,
      brightness: brightness,
      surface: c.bg,
      primary: c.accent,
      onPrimary: c.onAccent,
      error: c.danger,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: [c],
      fontFamily: OblixType.sans,
      scaffoldBackgroundColor: c.bg,
      splashFactory: InkSparkle.splashFactory,
      dividerColor: c.hairline,
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        foregroundColor: c.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.ink,
        contentTextStyle: TextStyle(
          fontFamily: OblixType.sans,
          fontSize: 13.5,
          color: brightness == Brightness.light ? c.surface : c.bg,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: TextStyle(
          fontFamily: OblixType.serif,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: c.ink,
        ),
        contentTextStyle: OblixType.ui(c, size: 14),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.accent,
        selectionColor: c.accent.withValues(alpha: 0.25),
        selectionHandleColor: c.accent,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent),
    );
  }

  static ThemeData get lightTheme =>
      _base(OblixColors.light, Brightness.light);
  static ThemeData get darkTheme => _base(OblixColors.dark, Brightness.dark);
}
