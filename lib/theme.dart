import 'package:flutter/cupertino.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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

  // Pure-neutral grayscale (R=G=B) — no blue/purple tint. Each surface is
  // one step lighter than the last so the hierarchy still reads:
  //   scaffold < sidebar < content < header < card < hover < divider < selected
  static const AppPalette dark = AppPalette(
    sidebarBg: Color(0xFF1A1A1A),
    sidebarHover: Color(0xFF2A2A2A),
    sidebarSelected: Color(0xFF3A3A3A),
    sidebarHeader: Color(0xFF8C8C8C),
    contentBg: Color(0xFF1F1F1F),
    divider: Color(0xFF2E2E2E),
    headerBg: Color(0xFF242424),
    subtleText: Color(0xFF9A9A9A),
    text: Color(0xFFEDEDED),
    folderIcon: Color(0xFF4D9BF5),
    accent: Color(0xFF0A84FF),
    // Bubbles are differentiated by lightness, not hue, to stay neutral.
    chatUserBubble: Color(0xFF3A3A3A),
    chatAssistantBubble: Color(0xFF262626),
    success: Color(0xFF32D74B),
    danger: Color(0xFFFF453A),
    rowAlt: Color(0xFF232323),
    cardBg: Color(0xFF262626),
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

/// Label size inside menus. Matches the file listing and the panels rather than
/// Shad's 14px default, so a menu doesn't read as a different app.
const double kMenuFontSize = 13;

/// Glyph size inside menus — a touch above [kMenuFontSize] so an icon's body
/// matches the label's cap height, which is how the platform's own menus look.
/// Shad would otherwise inherit the app-wide 16px IconTheme.
const double kMenuIconSize = 14;

class AppTheme {
  /// Maps [AppPalette] onto shadcn's colour-scheme slots so Shad components
  /// inherit the app's existing look instead of a stock zinc/slate scheme.
  ///
  /// Note the shadcn naming: `primary` is the brand colour, while `accent` is
  /// the *subtle hover surface* — not the brand. Getting those two backwards
  /// makes every hovered row light up bright blue.
  static ShadColorScheme shadColorSchemeFor(Brightness brightness) {
    final p = brightness == Brightness.dark
        ? AppPalette.dark
        : AppPalette.light;
    const onAccent = Color(0xFFFFFFFF);
    return ShadColorScheme(
      background: p.contentBg,
      foreground: p.text,
      card: p.cardBg,
      cardForeground: p.text,
      popover: p.cardBg,
      popoverForeground: p.text,
      primary: p.accent,
      primaryForeground: onAccent,
      secondary: p.sidebarHover,
      secondaryForeground: p.text,
      muted: p.headerBg,
      mutedForeground: p.subtleText,
      accent: p.sidebarHover,
      accentForeground: p.text,
      destructive: p.danger,
      destructiveForeground: onAccent,
      border: p.divider,
      input: p.divider,
      ring: p.accent,
      selection: p.accent.withValues(alpha: 0.3),
    );
  }

  static ShadThemeData shadThemeFor(Brightness brightness) {
    final palette = brightness == Brightness.dark
        ? AppPalette.dark
        : AppPalette.light;
    return ShadThemeData(
      brightness: brightness,
      colorScheme: shadColorSchemeFor(brightness),
      radius: BorderRadius.circular(8),
      textTheme: ShadTextTheme(family: '.SF Pro Text'),
      // The app is a desktop file manager — 13px is the established body size
      // across every panel, so Shad's 14px default would break alignment with
      // the not-yet-migrated widgets.
      inputTheme: ShadInputTheme(
        style: TextStyle(fontSize: 13, color: palette.text),
        placeholderStyle: TextStyle(fontSize: 13, color: palette.subtleText),
      ),
      // Same reasoning for cards: Shad defaults to 24px padding, which is airy
      // for a web page and wrong for panels that already sit inside a 16px
      // gutter and stack several to a row.
      cardTheme: const ShadCardTheme(padding: EdgeInsets.all(14)),
      // Context menus default to 32px rows and 14px labels, which next to a
      // 13px file listing reads as a different app. Tightened to the density
      // the platform's own menus use: a 26px row, 13px label, and a hairline
      // gap so a long menu doesn't run the height of the window.
      contextMenuTheme: ShadContextMenuTheme(
        height: 26,
        textStyle: TextStyle(
          fontSize: kMenuFontSize,
          color: palette.text,
          fontWeight: FontWeight.normal,
        ),
        itemPadding: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 4),
        leadingPadding: const EdgeInsetsDirectional.only(end: 8),
        trailingPadding: const EdgeInsetsDirectional.only(start: 10),
      ),
      // A checkbox is 16px and inherits `radius` above, so the global 8 rounds
      // it into a perfect circle — it reads as a radio button, i.e. as
      // single-select, which is wrong wherever several can be ticked at once.
      checkboxTheme: ShadCheckboxTheme(
        decoration: ShadDecoration(
          border: ShadBorder(radius: BorderRadius.circular(4)),
        ),
      ),
    );
  }

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
        // These two must use inherit:false to match Cupertino's built-in nav
        // text styles. During a nav-bar→nav-bar push transition Flutter lerps
        // the title into the back-button label; mixing inherit:true here with
        // the framework's inherit:false defaults throws "Failed to interpolate
        // TextStyles with different inherit values."
        navTitleTextStyle: TextStyle(
          inherit: false,
          fontFamily: '.SF Pro Text',
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: palette.text,
          decoration: TextDecoration.none,
        ),
        navActionTextStyle: TextStyle(
          inherit: false,
          fontFamily: '.SF Pro Text',
          fontSize: 15,
          color: palette.accent,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}
