import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons, ShadTheme;

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../providers/file_ops_provider.dart';
import '../services/remote/remote_hub.dart';
import '../services/remote/remote_path.dart';
import '../services/text_document_service.dart';
import '../theme.dart';
import '../widgets/window_chrome.dart';

/// Opens [entry] in the editor. Returns true if anything was saved, so the
/// caller can refresh a listing whose size and date just changed.
Future<bool> openTextEditor(BuildContext context, FileEntry entry) async {
  final saved = await Navigator.of(context).push<bool>(
    CupertinoPageRoute(builder: (_) => TextEditorScreen(entry: entry)),
  );
  return saved ?? false;
}

/// A plain text editor for one file, local or on any mounted remote source.
///
/// It is a full screen rather than a mode of the preview viewer: the preview is
/// a read surface — swipe between siblings, filmstrip, a toolbar that assumes
/// nothing is at stake — and an editor needs the opposite, which is one file,
/// unsaved-change tracking, and a close that can refuse.
///
/// There is no syntax highlighting. Doing it honestly means a grammar per
/// language and a dependency to match; monospace text with the structure the
/// author put there is the useful 90% of editing a config file on a server.
class TextEditorScreen extends StatefulWidget {
  const TextEditorScreen({super.key, required this.entry});

  final FileEntry entry;

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends State<TextEditorScreen> {
  static const _service = TextDocumentService();

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'TextEditor');
  final ScrollController _scroll = ScrollController();

  TextDocument? _document;
  String _savedText = '';
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _justSaved = false;

  /// Whether anything was written during this session, so the caller knows
  /// whether the listing it came from is now out of date.
  bool _savedAny = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _load();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    _focusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    final dirty = _controller.text != _savedText;
    if (dirty != _dirty || _justSaved) {
      setState(() {
        _dirty = dirty;
        _justSaved = false;
      });
    } else {
      // The caret moved; the status bar shows line and column, so it still has
      // to rebuild — but nothing else has changed.
      setState(() {});
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final document = await _service.load(widget.entry.path);
      if (!mounted) return;
      setState(() {
        _document = document;
        _savedText = document.text;
        _controller.text = document.text;
        _loading = false;
        _dirty = false;
      });
      _focusNode.requestFocus();
    } on TextEditException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final document = _document;
    if (document == null || _saving) return;
    setState(() => _saving = true);
    final text = _controller.text;
    try {
      var stamp = await _service.save(document, text);
      if (!mounted) return;
      await _afterSave(document, text, stamp);
    } on TextConflictException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final overwrite = await _askOverwrite(e.detail);
      if (overwrite != true || !mounted) return;
      setState(() => _saving = true);
      try {
        final stamp = await _service.save(document, text, force: true);
        if (!mounted) return;
        await _afterSave(document, text, stamp);
      } on TextEditException catch (e) {
        if (mounted) await _failSave(e.message);
      }
    } on TextEditException catch (e) {
      if (mounted) await _failSave(e.message);
    } catch (e) {
      if (mounted) await _failSave('$e');
    }
  }

  Future<void> _afterSave(
    TextDocument document,
    String text,
    TextStamp stamp,
  ) async {
    // A remote file that was previewed earlier has a downloaded copy sitting in
    // the cache; it is now wrong.
    if (document.isRemote) {
      await context.read<FileOpsProvider>().forgetCachedCopy(document.path);
    }
    if (!mounted) return;
    setState(() {
      _document = TextDocument(
        path: document.path,
        text: text,
        stamp: stamp,
        lineEnding: document.lineEnding,
        hasBom: document.hasBom,
      );
      _savedText = text;
      _dirty = false;
      _saving = false;
      _justSaved = true;
      _savedAny = true;
    });
    // The listing behind the editor shows a size and a date that just changed.
    final browser = context.read<BrowserProvider>();
    if (browser.currentPath == VPath.dirname(document.path)) {
      await browser.refresh();
    }
  }

  Future<void> _failSave(String message) async {
    setState(() => _saving = false);
    await _alert('Couldn\'t save', message);
  }

  Future<bool?> _askOverwrite(String detail) => showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Saved by someone else'),
          content: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '$detail\n\nSaving now replaces their version with yours.',
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Overwrite'),
            ),
          ],
        ),
      );

  Future<void> _alert(String title, String message) => showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text(title),
          content: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(message),
          ),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );

  Future<void> _revert() async {
    if (_dirty) {
      final ok = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Discard your changes?'),
          content: const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('The file will be re-read from where it lives.'),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _load();
  }

  /// Save / Discard / Cancel, for a close with unsaved work. Returns true when
  /// it is safe to leave.
  Future<bool> _confirmClose() async {
    if (!_dirty) return true;
    final choice = await showCupertinoDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Save changes to "${widget.entry.name}"?'),
        content: const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Your edits are lost if you close without saving.'),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('Discard'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (choice == 'save') {
      await _save();
      return !_dirty;
    }
    return choice == 'discard';
  }

  Future<void> _close() async {
    final navigator = Navigator.of(context);
    if (!await _confirmClose()) return;
    if (mounted) navigator.pop(_savedAny);
  }

  // ── keyboard ─────────────────────────────────────────────────────────────

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final mod = keys.isMetaPressed || keys.isControlPressed;

    if (mod && event.logicalKey == LogicalKeyboardKey.keyS) {
      _save();
      return KeyEventResult.handled;
    }
    if (mod && event.logicalKey == LogicalKeyboardKey.keyW) {
      _close();
      return KeyEventResult.handled;
    }
    // Tab indents instead of moving focus — in a code editor the traversal
    // behaviour is the wrong one, and there is nowhere else to tab to.
    if (event.logicalKey == LogicalKeyboardKey.tab && !mod) {
      _insertIndent(outdent: keys.isShiftPressed);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static const String _indent = '  ';

  void _insertIndent({required bool outdent}) {
    final value = _controller.value;
    final selection = value.selection;
    if (!selection.isValid) return;

    if (!outdent) {
      final text = value.text.replaceRange(
        selection.start,
        selection.end,
        _indent,
      );
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
          offset: selection.start + _indent.length,
        ),
      );
      return;
    }

    // Shift+Tab removes one indent from the start of the caret's line.
    final lineStart = value.text.lastIndexOf('\n', selection.start - 1) + 1;
    if (!value.text.startsWith(_indent, lineStart)) return;
    final text = value.text.replaceRange(
      lineStart,
      lineStart + _indent.length,
      '',
    );
    const shift = _indent.length;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: (selection.start - shift).clamp(lineStart, text.length),
      ),
    );
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);

    return PopScope<bool>(
      // A back gesture or Escape can't take unsaved work with it; the guard
      // asks, then pops itself if the answer allows.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmClose() && mounted) {
          navigator.pop(_savedAny);
        }
      },
      child: CupertinoPageScaffold(
        backgroundColor: palette.scaffoldBg,
        navigationBar: _navigationBar(palette),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(child: _body(palette)),
              if (_document != null)
                _StatusBar(
                  document: _document!,
                  controller: _controller,
                  dirty: _dirty,
                  justSaved: _justSaved,
                ),
            ],
          ),
        ),
      ),
    );
  }

  ObstructingPreferredSizeWidget _navigationBar(AppPalette palette) {
    final remoteLabel = RemoteHub.instance.labelForPath(widget.entry.path);
    return CupertinoNavigationBar(
      backgroundColor: palette.headerBg,
      border: Border(bottom: BorderSide(color: palette.divider)),
      // The editor fills the window, so its bar is where macOS draws the
      // traffic lights; without the inset they sit on the back button.
      padding: EdgeInsetsDirectional.only(
        start: windowLeadingInset(atWindowEdge: true),
      ),
      leading: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: _close,
        child: const Icon(CupertinoIcons.back, size: 24),
      ),
      middle: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _dirty ? '${widget.entry.name} •' : widget.entry.name,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: palette.text),
          ),
          if (remoteLabel != null)
            Text(
              remoteLabel,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: palette.subtleText),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            onPressed: _loading || _saving ? null : _revert,
            child: Icon(
              CupertinoIcons.arrow_counterclockwise,
              size: 18,
              color: _loading || _saving ? palette.subtleText : palette.accent,
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            onPressed: _dirty && !_saving ? _save : null,
            child: _saving
                ? const CupertinoActivityIndicator(radius: 8)
                : Text(
                    'Save',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _dirty ? palette.accent : palette.subtleText,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _body(AppPalette palette) {
    if (_loading) return const Center(child: CupertinoActivityIndicator());

    final error = _error;
    if (error != null) {
      final colors = ShadTheme.of(context).colorScheme;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.fileWarning, size: 30, color: colors.destructive),
              const SizedBox(height: 12),
              Text(
                'Can\'t edit this file',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: palette.subtleText),
              ),
            ],
          ),
        ),
      );
    }

    return Focus(
      onKeyEvent: _onKey,
      child: CupertinoTextField(
        controller: _controller,
        focusNode: _focusNode,
        // expands + null maxLines is what makes the field fill the pane and
        // scroll internally, rather than growing a page that scrolls the whole
        // screen out from under the caret.
        maxLines: null,
        expands: true,
        scrollController: _scroll,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        // The OS "helpful" text behaviours are wrong for source code: an
        // autocapitalised keyword and a smart quote both break the file.
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        textCapitalization: TextCapitalization.none,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(color: palette.contentBg),
        cursorColor: palette.accent,
        style: TextStyle(
          fontFamily: 'Menlo',
          fontSize: 12.5,
          height: 1.5,
          color: palette.text,
        ),
      ),
    );
  }
}

/// Line, column, and the facts a save depends on — the line ending and the
/// BOM — so the file's shape is visible rather than implied.
class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.document,
    required this.controller,
    required this.dirty,
    required this.justSaved,
  });

  final TextDocument document;
  final TextEditingController controller;
  final bool dirty;
  final bool justSaved;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final text = controller.text;
    final offset = controller.selection.isValid
        ? controller.selection.baseOffset.clamp(0, text.length)
        : 0;
    final before = text.substring(0, offset);
    final line = '\n'.allMatches(before).length + 1;
    final column = offset - (before.lastIndexOf('\n') + 1) + 1;
    final lines = '\n'.allMatches(text).length + 1;

    final parts = <String>[
      'Ln $line, Col $column',
      '$lines ${lines == 1 ? 'line' : 'lines'}',
      document.lineEnding.label,
      document.hasBom ? 'UTF-8 BOM' : 'UTF-8',
    ];

    return Container(
      height: 24,
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join('  ·  '),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: palette.subtleText),
            ),
          ),
          if (justSaved)
            Text(
              'Saved',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: palette.success,
              ),
            )
          else if (dirty)
            Text(
              'Unsaved changes',
              style: TextStyle(fontSize: 11, color: palette.subtleText),
            ),
        ],
      ),
    );
  }
}
