import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

const Color kBackground = Color(0xFF0A0A0F);
const Color kAccentRed = Color(0xFFFF3B3B);
const Color kAccentGreen = Color(0xFF00FF87);
const Color kBombBody = Color(0xFF1A1A2E);
const Color kBombBorder = Color(0xFF2A2A4E);
const Color kTextPrimary = Color(0xFFFFFFFF);
const Color kTextSecondary = Color(0xFF8A8A9A);
const Color kHeartActive = Color(0xFFFF3B3B);
const Color kHeartInactive = Color(0xFF3A2A2A);
const Color kButtonBg = Color(0xFF1E1E30);
const Color kInputBg = Color(0xFF12121E);

ThemeData buildAppTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: kBackground,
    colorScheme: const ColorScheme.dark(
      primary: kAccentRed,
      secondary: kAccentGreen,
      surface: kBombBody,
      onPrimary: kTextPrimary,
      onSecondary: kBackground,
      onSurface: kTextPrimary,
    ),
    textTheme: GoogleFonts.orbitronTextTheme(
      const TextTheme(
        displayLarge: TextStyle(color: kTextPrimary),
        displayMedium: TextStyle(color: kTextPrimary),
        displaySmall: TextStyle(color: kTextPrimary),
        headlineLarge: TextStyle(color: kTextPrimary),
        headlineMedium: TextStyle(color: kTextPrimary),
        headlineSmall: TextStyle(color: kTextPrimary),
        titleLarge: TextStyle(color: kTextPrimary),
        titleMedium: TextStyle(color: kTextPrimary),
        titleSmall: TextStyle(color: kTextPrimary),
        bodyLarge: TextStyle(color: kTextPrimary),
        bodyMedium: TextStyle(color: kTextPrimary),
        bodySmall: TextStyle(color: kTextSecondary),
        labelLarge: TextStyle(color: kTextPrimary),
        labelMedium: TextStyle(color: kTextPrimary),
        labelSmall: TextStyle(color: kTextSecondary),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kInputBg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: kBombBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: kBombBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: kAccentRed, width: 2),
      ),
      hintStyle: const TextStyle(color: kTextSecondary),
      labelStyle: const TextStyle(color: kTextSecondary),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: kAccentRed,
        foregroundColor: kTextPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: GoogleFonts.orbitron(fontWeight: FontWeight.bold),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: kBackground,
      foregroundColor: kTextPrimary,
      elevation: 0,
      titleTextStyle: GoogleFonts.orbitron(
        color: kTextPrimary,
        fontSize: 18,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}
