import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/theme.dart';
import 'package:notilus/utils/platform.dart';
import 'package:notilus/widgets/desk_context_menu.dart';

/// The file/folder right-click menu, now rendered by [ShadContextMenu].
///
/// It stays imperative — `showDeskContextMenu(context, globalPosition:, items:)`
/// — because the list and grid already arbitrate which of a row or the
/// background claimed the gesture. These tests drive that entry point directly.
void main() {
  Widget host({Brightness brightness = Brightness.light}) {
    return ShadApp.custom(
      theme: AppTheme.shadThemeFor(Brightness.light),
      darkTheme: AppTheme.shadThemeFor(Brightness.dark),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      appBuilder: (_) => CupertinoApp(
        localizationsDelegates: const [
          GlobalShadLocalizations.delegate,
          DefaultMaterialLocalizations.delegate,
          DefaultCupertinoLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        builder: (_, inner) => ShadAppBuilder(child: inner!),
        // The menu inserts into the root overlay, so all it needs is a route.
        home: const SizedBox.expand(),
      ),
    );
  }

  /// Pumps the app, then opens a menu at [at] from the current route's context.
  Future<void> open(
    WidgetTester tester,
    List<DeskMenuItem> items, {
    Offset at = const Offset(200, 200),
    Size size = const Size(1000, 800),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(brightness: brightness));
    await tester.pumpAndSettle();

    showDeskContextMenu(
      tester.element(find.byType(SizedBox).first),
      globalPosition: at,
      items: items,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  List<DeskMenuItem> fileItems({
    VoidCallback? onRename,
    bool pasteEnabled = false,
    bool hiddenShown = false,
  }) =>
      [
        DeskMenuItem(
          label: 'Open',
          icon: LucideIcons.externalLink,
          onTap: () {},
        ),
        DeskMenuItem(
          label: 'Open With',
          icon: LucideIcons.share2,
          submenu: [
            DeskMenuItem(
              label: 'Default Application',
              icon: LucideIcons.appWindow,
              onTap: () {},
            ),
            DeskMenuItem.divider(),
            DeskMenuItem(
              label: 'Choose Application…',
              icon: LucideIcons.ellipsis,
              onTap: () {},
            ),
          ],
        ),
        DeskMenuItem.divider(),
        DeskMenuItem(
          label: 'Rename…',
          icon: LucideIcons.pencil,
          onTap: onRename ?? () {},
        ),
        DeskMenuItem(
          label: 'Paste',
          icon: LucideIcons.clipboardPaste,
          enabled: pasteEnabled,
        ),
        DeskMenuItem.divider(),
        DeskMenuItem(
          label: 'Show Hidden Files/Folders',
          checked: hiddenShown,
          onTap: () {},
        ),
      ];

  group('rendering', () {
    for (final brightness in Brightness.values) {
      testWidgets('opens without overflow ($brightness)', (tester) async {
        await open(tester, fileItems(), brightness: brightness);
        // Not byType(ShadContextMenu): every ShadContextMenuItem nests one of
        // its own for a possible submenu, so that finder counts 1 + one per row.
        expect(find.byType(ShadContextMenuItem), findsNWidgets(5));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('renders every non-divider entry', (tester) async {
      await open(tester, fileItems());

      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Open With'), findsOneWidget);
      expect(find.text('Rename…'), findsOneWidget);
      expect(find.text('Paste'), findsOneWidget);
      expect(find.text('Show Hidden Files/Folders'), findsOneWidget);
      // Submenu entries stay closed until the parent is opened.
      expect(find.text('Default Application'), findsNothing);
    });

    testWidgets('dividers become separators, not menu rows', (tester) async {
      await open(tester, fileItems());

      // Two dividers at the fixture's top level; the third lives inside the
      // closed submenu and so is not built yet.
      expect(find.byType(ShadSeparator), findsNWidgets(2));
      // A divider must never be tappable.
      expect(find.byType(ShadContextMenuItem), findsNWidgets(5));
    });

    testWidgets('a submenu parent gets a chevron, a leaf does not',
        (tester) async {
      await open(tester, fileItems());

      expect(find.byIcon(LucideIcons.chevronRight), findsOneWidget);
      expect(find.byIcon(LucideIcons.externalLink), findsOneWidget);
      expect(find.byIcon(LucideIcons.pencil), findsOneWidget);
    });

    testWidgets('a checked toggle shows a tick, an unchecked one does not',
        (tester) async {
      await open(tester, fileItems(hiddenShown: true));
      expect(find.byIcon(LucideIcons.check), findsOneWidget);

      await open(tester, fileItems());
      expect(find.byIcon(LucideIcons.check), findsNothing);
    });

    testWidgets('a disabled entry renders but is not pressable',
        (tester) async {
      await open(tester, fileItems(pasteEnabled: false));

      final paste = tester.widget<ShadContextMenuItem>(
        find.ancestor(
          of: find.text('Paste'),
          matching: find.byType(ShadContextMenuItem),
        ),
      );
      expect(paste.enabled, isFalse);
      expect(paste.onPressed, isNull);
    });
  });

  group('density', () {
    // Shad defaults a menu to 32px rows, 14px labels and (via the app-wide
    // IconTheme) 16px glyphs, which next to a 13px file listing reads as a
    // different app. These pin it to the app's own scale.
    testWidgets('labels use the app body size, not Shad\'s larger default',
        (tester) async {
      await open(tester, fileItems());

      final style = DefaultTextStyle.of(
        tester.element(find.text('Rename…')),
      ).style;
      expect(style.fontSize, kMenuFontSize);
      expect(kMenuFontSize, lessThan(14), reason: 'must beat Shad\'s default');
    });

    testWidgets('glyphs match the label rather than the 16px IconTheme',
        (tester) async {
      await open(tester, fileItems());

      final pencil = tester.widget<Icon>(find.byIcon(LucideIcons.pencil));
      expect(pencil.size, kMenuIconSize);

      // The submenu chevron is deliberately a shade smaller than a content
      // glyph, and neither inherits the app-wide 16.
      final chevron =
          tester.widget<Icon>(find.byIcon(LucideIcons.chevronRight));
      expect(chevron.size, lessThan(kMenuIconSize));
      expect(pencil.size, lessThan(16));
    });

    testWidgets('rows are compact', (tester) async {
      await open(tester, fileItems());

      final row = tester.getRect(
        find.ancestor(
          of: find.text('Rename…'),
          matching: find.byType(ShadContextMenuItem),
        ),
      );
      // Shad's default row is 32; the theme pins 26 plus the item's own 4px
      // vertical padding.
      expect(row.height, lessThanOrEqualTo(32));
    });

    testWidgets('a checked and an unchecked row align on the same baseline',
        (tester) async {
      // The empty leading slot is what keeps a toggle's label from shifting
      // sideways as it flips.
      await open(tester, fileItems(hiddenShown: true));
      final onLeft = tester.getTopLeft(find.text('Show Hidden Files/Folders')).dx;

      await open(tester, fileItems());
      final offLeft = tester.getTopLeft(find.text('Show Hidden Files/Folders')).dx;

      expect(offLeft, onLeft);
    });
  });

  group('behaviour', () {
    testWidgets('choosing an entry runs its action and closes the menu',
        (tester) async {
      var renamed = 0;
      await open(tester, fileItems(onRename: () => renamed++));

      await tester.tap(find.text('Rename…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(renamed, 1);
      expect(find.byType(ShadContextMenuItem), findsNothing);
    });

    testWidgets('clicking outside dismisses without running anything',
        (tester) async {
      var renamed = 0;
      await open(tester, fileItems(onRename: () => renamed++));
      expect(find.byType(ShadContextMenuItem), findsNWidgets(5));

      // Far from the menu, which opened at (200, 200).
      await tester.tapAt(const Offset(900, 700));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(ShadContextMenuItem), findsNothing);
      expect(renamed, 0);
    });

    testWidgets('opening a second menu replaces the first', (tester) async {
      await open(tester, fileItems());
      expect(find.text('Rename…'), findsOneWidget);

      showDeskContextMenu(
        tester.element(find.byType(SizedBox).first),
        globalPosition: const Offset(400, 300),
        items: [DeskMenuItem(label: 'Only me', onTap: () {})],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Never two menus stacked: the first menu's rows are gone entirely.
      expect(find.byType(ShadContextMenuItem), findsOneWidget);
      expect(find.text('Only me'), findsOneWidget);
      expect(find.text('Rename…'), findsNothing);
    });
  });

  group('submenus', () {
    // The riskiest part of the migration: the old menu hand-rolled submenus
    // with a LayerLink and a nested OverlayEntry, tracked by index on hover.
    testWidgets('hovering a parent opens its submenu', (tester) async {
      await open(tester, fileItems());
      expect(find.text('Default Application'), findsNothing);

      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('Open With')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Default Application'), findsOneWidget);
      expect(find.text('Choose Application…'), findsOneWidget);
      // The submenu's own divider builds once it is open.
      expect(find.byType(ShadSeparator), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a submenu opens clear of the menu it came from',
        (tester) async {
      await open(tester, fileItems());

      final parent = find.ancestor(
        of: find.text('Open With'),
        matching: find.byType(ShadContextMenuItem),
      );
      final parentRect = tester.getRect(parent);

      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('Open With')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // Sits to the right of the parent row rather than on top of it, which is
      // what made shadcn's default anchor unusable — the parent menu's own rows
      // covered the submenu and swallowed the click.
      // .first is the leaf itself: a submenu is built inside its parent item's
      // subtree, so find.ancestor matches the leaf and then the parent.
      final subRect = tester.getRect(
        find
            .ancestor(
              of: find.text('Default Application'),
              matching: find.byType(ShadContextMenuItem),
            )
            .first,
      );
      expect(subRect.left, greaterThanOrEqualTo(parentRect.right - 1));
    });

    testWidgets('choosing a submenu leaf runs it and closes the whole menu',
        (tester) async {
      var chosen = 0;
      await open(tester, [
        DeskMenuItem(
          label: 'Open With',
          icon: LucideIcons.share2,
          submenu: [
            DeskMenuItem(
              label: 'Default Application',
              icon: LucideIcons.appWindow,
              onTap: () => chosen++,
            ),
          ],
        ),
        DeskMenuItem(label: 'Rename…', onTap: () {}),
      ]);

      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('Open With')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      await tester.tap(find.text('Default Application'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(chosen, 1);
      // A leaf inside a submenu must tear down the root menu too, not just its
      // own level.
      expect(find.byType(ShadContextMenuItem), findsNothing);
    });
  });

  group('submenus on a touchscreen', () {
    // shadcn opens a submenu while its parent row is hovered or focused, and a
    // finger is neither: on a phone the second menu simply never appeared. The
    // phone drills into the submenu in place instead.
    setUp(() => debugMobilePlatformOverride = true);
    tearDown(() => debugMobilePlatformOverride = null);

    testWidgets('tapping a parent replaces the menu with its submenu',
        (tester) async {
      await open(tester, fileItems());
      expect(find.text('Default Application'), findsNothing);

      await tester.tap(find.text('Open With'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Default Application'), findsOneWidget);
      expect(find.text('Choose Application…'), findsOneWidget);
      // In place, not beside: the level it came from is gone, and the row that
      // opened it is now the way back.
      expect(find.text('Rename…'), findsNothing);
      expect(find.byIcon(LucideIcons.chevronLeft), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the back row returns to the level above', (tester) async {
      await open(tester, fileItems());

      await tester.tap(find.text('Open With'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The back row is labelled with where you are, so it also names the level.
      await tester.tap(find.byIcon(LucideIcons.chevronLeft));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Rename…'), findsOneWidget);
      expect(find.text('Default Application'), findsNothing);
      expect(find.byIcon(LucideIcons.chevronLeft), findsNothing);
    });

    testWidgets('drilling in does not close the menu or run the parent',
        (tester) async {
      await open(tester, fileItems());

      await tester.tap(find.text('Open With'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(ShadContextMenuItem), findsWidgets);
    });

    testWidgets('a leaf two levels down runs and closes the whole menu',
        (tester) async {
      var sorted = 0;
      await open(tester, [
        DeskMenuItem(
          label: 'View',
          icon: LucideIcons.layoutGrid,
          submenu: [
            DeskMenuItem(
              label: 'Sort By',
              submenu: [
                DeskMenuItem(label: 'Name', onTap: () => sorted++),
              ],
            ),
          ],
        ),
      ]);

      for (final label in ['View', 'Sort By', 'Name']) {
        await tester.tap(find.text(label));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      expect(sorted, 1);
      expect(find.byType(ShadContextMenuItem), findsNothing);
    });
  });

  group('positioning', () {
    // The old implementation clamped the menu to the viewport by hand from an
    // estimated height. ShadPopover flips/shifts itself, so what matters now is
    // simply that a corner anchor still renders fully on screen.
    for (final at in const [
      Offset(4, 4),
      Offset(996, 4),
      Offset(4, 796),
      Offset(996, 796),
    ]) {
      testWidgets('stays on screen anchored at (${at.dx}, ${at.dy})',
          (tester) async {
        await open(tester, fileItems(), at: at);

        final rect = tester.getRect(find.byType(ShadContextMenuItem).first);
        expect(rect.left, greaterThanOrEqualTo(-0.5));
        expect(rect.top, greaterThanOrEqualTo(-0.5));
        expect(rect.right, lessThanOrEqualTo(1000.5));
        expect(rect.bottom, lessThanOrEqualTo(800.5));
        expect(tester.takeException(), isNull);
      });
    }
  });
}
