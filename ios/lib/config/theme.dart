import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Colors
  static const Color bg = Color(0xFF12141C);
  static const Color bgCard = Color(0xFF181B23);
  static const Color bgSurface = Color(0xFF1E2130);
  static const Color accent = Color(0xFFF5C518);
  static const Color accentDim = Color(0x26F5C518); // rgba(245,197,24,0.15)
  static const Color gold = Color(0xFFE8C547);
  static const Color textPrimary = Color(0xFFF0F0F0);
  static const Color textSub = Color(0xFF9AA0B4);
  static const Color textMuted = Color(0xFF5C627A);
  static const Color border = Color(0x40FFFFFF);

  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.dark(
      primary: accent,
      secondary: gold,
      surface: bgSurface,
      onPrimary: bg,
      onSecondary: bg,
      onSurface: textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: bg,
      dividerColor: border,

      // Headings — Inter cho nét gọn, dễ đọc trên mobile
      textTheme: GoogleFonts.interTextTheme(
        ThemeData.dark().textTheme.copyWith(
              displayLarge: GoogleFonts.inter(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: textPrimary,
              ),
              displayMedium: GoogleFonts.inter(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: textPrimary,
              ),
              displaySmall: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
              headlineLarge: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
              headlineMedium: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
              headlineSmall: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
      ),

      // Body — BeVietnamPro giữ nguyên cho tiếng Việt
      primaryTextTheme: GoogleFonts.beVietnamProTextTheme(
        ThemeData.dark().primaryTextTheme,
      ),

      // Card
      cardColor: bgCard,
      cardTheme: CardThemeData(
        color: bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
      ),

      // Bottom Navigation
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: bgSurface,
        selectedItemColor: accent,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),

      // Input
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent),
        ),
        hintStyle: const TextStyle(color: textMuted),
      ),

      // Elevated Button
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // Chip
      chipTheme: ChipThemeData(
        backgroundColor: bgSurface,
        labelStyle: const TextStyle(color: textSub),
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
