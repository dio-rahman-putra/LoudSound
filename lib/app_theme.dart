import 'package:flutter/material.dart';

/// Palet warna gelap. UI sengaja netral; warna hanya dipakai untuk
/// menandai level suara dan status koneksi.
abstract final class AppColors {
  static const background = Color(0xFF0A0B0D);
  static const surface = Color(0xFF111317);
  static const surfaceRaised = Color(0xFF181B20);
  static const border = Color(0xFF1F2329);
  static const borderStrong = Color(0xFF2B3039);

  static const textPrimary = Color(0xFFECEEF1);
  static const textSecondary = Color(0xFF8E959F);
  static const textMuted = Color(0xFF575D67);

  static const quiet = Color(0xFF4FD1A5);
  static const normal = Color(0xFFF2B84B);
  static const loud = Color(0xFFF0624D);
}

enum NoiseLevel {
  quiet('Pelan', '< 60 dB', 'Lingkungan tenang dan aman.', AppColors.quiet),
  normal('Normal', '60–85 dB', 'Tingkat kebisingan wajar.', AppColors.normal),
  loud(
    'Berisik',
    '> 85 dB',
    'Melewati batas aman, kurangi sumber bising.',
    AppColors.loud,
  );

  const NoiseLevel(this.label, this.range, this.description, this.color);

  final String label;
  final String range;
  final String description;
  final Color color;

  static NoiseLevel fromDb(double db) {
    if (db < 60) return NoiseLevel.quiet;
    if (db <= 85) return NoiseLevel.normal;
    return NoiseLevel.loud;
  }
}

abstract final class AppText {
  static const _tabular = [FontFeature.tabularFigures()];

  static const label = TextStyle(
    color: AppColors.textMuted,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.3,
  );

  static TextStyle number(
    double size, {
    Color color = AppColors.textPrimary,
    FontWeight weight = FontWeight.w300,
  }) {
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: 1,
      letterSpacing: -size * 0.03,
      fontFeatures: _tabular,
    );
  }
}

BoxDecoration panelDecoration({double radius = 20, Color? color}) {
  return BoxDecoration(
    color: color ?? AppColors.surface,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: AppColors.border),
  );
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Roboto',
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: const ColorScheme.dark(
      surface: AppColors.surface,
      surfaceTint: Colors.transparent,
      primary: AppColors.textPrimary,
      onPrimary: AppColors.background,
      secondary: AppColors.quiet,
      error: AppColors.loud,
    ),
    dividerColor: AppColors.border,
    splashFactory: InkRipple.splashFactory,
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.textPrimary,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.textPrimary,
      selectionColor: Color(0x33ECEEF1),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceRaised,
      contentTextStyle: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 13,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.borderStrong),
      ),
    ),
  );
}
