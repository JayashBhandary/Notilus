import 'package:flutter/cupertino.dart';

/// Resolved app palette. Two const instances ([light] and [dark]) are exposed.
/// Use [AppColors.of] in widgets that should react to the active theme.
class AppPalette {
  const AppPalette({
    required this.sidebarBg,
    required this.sidebarHover,
    required this.sidebarSelected,
    required this.sidebarHeader,
    required this.contentBg,
    required this.divider,
    required this.headerBg,
    required this.subtleText,
    required this.text,
    required this.folderIcon,
    required this.accent,
    required this.chatUserBubble,
    required this.chatAssistantBubble,
    required this.success,
    required this.danger,
    required this.rowAlt,
    required this.cardBg,
    required this.scaffoldBg,
    required this.brightness,
  });

  final Color sidebarBg;
  final Color sidebarHover;
  final Color sidebarSelected;
  final Color sidebarHeader;
  final Color contentBg;
  final Color divider;
  final Color headerBg;
  final Color subtleText;
  final Color text;
  final Color folderIcon;
  final Color accent;
  final Color chatUserBubble;
  final Color chatAssistantBubble;
  final Color success;
  final Color danger;
  final Color rowAlt;
  final Color cardBg;
  final Color scaffoldBg;
  final Brightness brightness;

  static const AppPalette light = AppPalette(
    sidebarBg: Color(0xFFF1F1F4),
    sidebarHover: Color(0xFFE4E4E9),
    sidebarSelected: Color(0xFFD8D8DE),
    sidebarHeader: Color(0xFF7A7A82),
    contentBg: Color(0xFFFFFFFF),
    divider: Color(0xFFE0E0E4),
    headerBg: Color(0xFFF7F7F9),
    subtleText: Color(0xFF6E6E73),
    text: Color(0xFF1C1C1E),
    folderIcon: Color(0xFF4D9BF5),
    accent: Color(0xFF0A84FF),
    chatUserBubble: Color(0xFFE5F1FF),
    chatAssistantBubble: Color(0xFFF2F2F4),
    success: Color(0xFF34C759),
    danger: Color(0xFFFF3B30),
    rowAlt: Color(0xFFFBFBFC),
    cardBg: Color(0xFFFFFFFF),
    scaffoldBg: Color(0xFFF2F2F7),
    brightness: Brightness.light,
  );

  static const AppPalette dark = AppPalette(
    sidebarBg: Color(0xFF1F1F22),
    sidebarHover: Color(0xFF2A2A2E),
    sidebarSelected: Color(0xFF3A3A40),
    sidebarHeader: Color(0xFF8E8E93),
    contentBg: Color(0xFF1C1C1E),
    divider: Color(0xFF2E2E32),
    headerBg: Color(0xFF26262A),
    subtleText: Color(0xFF9A9AA0),
    text: Color(0xFFEDEDF0),
    folderIcon: Color(0xFF4D9BF5),
    accent: Color(0xFF0A84FF),
    chatUserBubble: Color(0xFF0F3D70),
    chatAssistantBubble: Color(0xFF2C2C30),
    success: Color(0xFF32D74B),
    danger: Color(0xFFFF453A),
    rowAlt: Color(0xFF202024),
    cardBg: Color(0xFF26262A),
    scaffoldBg: Color(0xFF000000),
    brightness: Brightness.dark,
  );
}

/// Resolves the active palette from context — switches automatically when
/// the CupertinoTheme brightness changes.
class AppColors {
  AppColors._();

  static AppPalette of(BuildContext context) {
    final brightness = CupertinoTheme.brightnessOf(context);
    return brightness == Brightness.dark
        ? AppPalette.dark
        : AppPalette.light;
  }
}

class AppTheme {
  static CupertinoThemeData themeFor(Brightness brightness) {
    final palette = brightness == Brightness.dark
        ? AppPalette.dark
        : AppPalette.light;
    return CupertinoThemeData(
      brightness: brightness,
      primaryColor: palette.accent,
      scaffoldBackgroundColor: palette.contentBg,
      barBackgroundColor: palette.headerBg,
      textTheme: CupertinoTextThemeData(
        textStyle: TextStyle(
          fontFamily: '.SF Pro Text',
          fontSize: 13,
          color: palette.text,
        ),
        navTitleTextStyle: TextStyle(
          fontFamily: '.SF Pro Text',
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: palette.text,
        ),
      ),
    );
  }
}
