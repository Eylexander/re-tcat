import 'package:flutter/material.dart';

/// Accent when the wallpaper's colors are unavailable (iOS, Android < 12).
const seed = Color(0xFF1F6FB2);

ThemeData buildTheme(ColorScheme cs) => ThemeData(
  colorScheme: cs,
  scaffoldBackgroundColor: cs.surface,
  appBarTheme: AppBarTheme(backgroundColor: cs.surface, surfaceTintColor: Colors.transparent),
  cardTheme: CardThemeData(
    elevation: 0,
    color: cs.surfaceContainerLow,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  ),
  snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
  listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 20)),
);
