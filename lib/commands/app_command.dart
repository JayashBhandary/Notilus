import 'package:flutter/cupertino.dart';

import 'key_combo.dart';

/// Where a command's shortcut is listened for.
///
/// This is not cosmetic — it decides *which* handler dispatches the key, and
/// therefore what has to be true for it to fire.
enum CommandScope {
  /// Listened for app-wide, ahead of focus dispatch. Reserved for combos that
  /// can never collide with text editing (all of them carry the primary
  /// modifier), since this fires even while a text field has focus.
  global,

  /// Listened for by the file list, so it needs the list focused and the
  /// centre pane showing files. This is where the editing keys live — Cmd+A,
  /// Cmd+C, Delete — precisely so text fields keep them.
  fileList,

  /// Listened for by the full-screen file preview route.
  preview,
}

/// Callbacks owned by `HomeScreen`'s state that commands need but can't reach
/// through a provider — panel visibility and dialogs.
@immutable
class HostActions {
  const HostActions({
    required this.toggleTerminal,
    required this.openSettings,
    required this.openPalette,
    required this.openShortcuts,
    required this.toggleSidebar,
    required this.toggleRightPanel,
    required this.refreshCenter,
  });

  final VoidCallback toggleTerminal;
  final VoidCallback openSettings;
  final VoidCallback openPalette;
  final VoidCallback openShortcuts;
  final VoidCallback toggleSidebar;
  final VoidCallback toggleRightPanel;

  /// Re-runs the active centre pane's own refresh (System Overview's scan),
  /// falling back to re-listing the folder.
  final VoidCallback refreshCenter;
}

/// Callbacks owned by the file preview route's state.
@immutable
class PreviewActions {
  const PreviewActions({
    required this.next,
    required this.previous,
    required this.close,
    required this.showInfo,
  });

  final VoidCallback next;
  final VoidCallback previous;
  final VoidCallback close;
  final VoidCallback showInfo;
}

/// Publishes [HostActions] to `HomeScreen`'s subtree.
///
/// Needed because the file list dispatches its own scoped shortcuts and some of
/// them reach host-level state. Routes pushed *above* the home screen — the
/// palette, the preview — are outside this subtree, so they receive the actions
/// directly instead of looking them up.
class CommandHost extends InheritedWidget {
  const CommandHost({
    super.key,
    required this.actions,
    required super.child,
  });

  final HostActions actions;

  /// Read without registering a dependency: the actions are stable for the
  /// life of the screen, and callers are key handlers rather than builds.
  static HostActions? maybeOf(BuildContext context) {
    final element =
        context.getElementForInheritedWidgetOfExactType<CommandHost>();
    return (element?.widget as CommandHost?)?.actions;
  }

  @override
  bool updateShouldNotify(CommandHost oldWidget) => false;
}

/// What a command gets to work with when it runs.
///
/// [host] and [preview] are scope-dependent: whoever dispatches supplies the
/// one its scope needs, so a [CommandScope.global] command can rely on [host]
/// and a [CommandScope.preview] command on [preview].
@immutable
class CommandEnv {
  const CommandEnv({required this.context, this.host, this.preview});

  final BuildContext context;
  final HostActions? host;
  final PreviewActions? preview;
}

/// A single user-invokable action: one definition feeding the key handlers,
/// the command palette and the shortcuts dialog at once.
@immutable
class AppCommand {
  const AppCommand({
    required this.id,
    required this.title,
    required this.category,
    required this.scope,
    required this.run,
    this.combo,
    this.extraCombos = const [],
    this.icon,
    this.isEnabled,
    this.inPalette = true,
    this.safeWhileTyping = false,
    this.keysNote,
  });

  final String id;
  final String title;

  /// Section heading in the shortcuts dialog, and the trailing hint in the
  /// palette.
  final String category;

  final CommandScope scope;
  final void Function(CommandEnv env) run;

  /// The primary shortcut, if it has one. Palette-only commands leave this null
  /// and are therefore absent from the shortcuts dialog.
  final KeyCombo? combo;

  /// Additional accepted bindings for the same action, for actions that have
  /// more than one idiomatic key — Move to Trash answers to both ⌫ and ⌘⌫ on
  /// macOS. Dispatch accepts any of them; the dialog shows them all.
  final List<KeyCombo> extraCombos;

  /// Every binding that triggers this command, primary first.
  List<KeyCombo> get combos => [if (combo != null) combo!, ...extraCombos];

  final IconData? icon;

  /// Whether the command can act right now — an empty selection disables Copy.
  /// A matched-but-disabled shortcut is left unhandled so the key can fall
  /// through to whatever else might want it.
  final bool Function(CommandEnv env)? isEnabled;

  /// Whether it appears in the palette. Preview-scope commands don't: their
  /// route isn't on screen when the palette is.
  final bool inPalette;

  /// Whether a [CommandScope.global] shortcut may fire while a text field has
  /// focus. False for anything that creates or mutates files, so Cmd+N while
  /// renaming doesn't quietly make a folder behind the dialog.
  final bool safeWhileTyping;

  /// Extra key hint shown in the dialog for combos with aliases — e.g. Enter
  /// also being Numpad Enter.
  final String? keysNote;

  bool enabledIn(CommandEnv env) => isEnabled?.call(env) ?? true;
}
