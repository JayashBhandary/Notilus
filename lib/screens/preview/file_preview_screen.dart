import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../models/file_entry.dart';
import '../../services/text_document_service.dart';
import '../../widgets/window_chrome.dart';
import '../text_editor_screen.dart';
import 'preview_common.dart';
import 'preview_filmstrip.dart';
import 'preview_info_panel.dart';
import 'preview_viewers.dart';

/// Full-screen Quick-Look-style viewer.
///
/// [files] is the list of sibling files in the current folder (directories
/// excluded) and [initialIndex] picks the one to open first.
///
/// The shell owns all chrome: a persistent top bar, an optional metadata side
/// panel, and an optional sibling filmstrip. Viewers only render content and
/// their own [PreviewToolbar]; they never draw a title bar or an info popup of
/// their own.
///
/// Keyboard: ← / → (or space) page between siblings, `I` toggles info,
/// `F` toggles the filmstrip, `Esc` closes.
class FilePreviewScreen extends StatefulWidget {
  const FilePreviewScreen({
    super.key,
    required this.files,
    required this.initialIndex,
    this.editEntry,
  });

  final List<FileEntry> files;
  final int initialIndex;

  /// What the Edit button should open, when it isn't the file being shown.
  ///
  /// A cloud file is previewed from a downloaded copy; editing that copy would
  /// write to a cache nobody reads back. The caller passes the original here,
  /// and the editor writes to the source.
  final FileEntry? editEntry;

  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<FilePreviewScreen> {
  late final PageController _pageController;
  late int _index;
  final _focusNode = FocusNode();

  bool _infoOpen = false;
  bool _stripOpen = false;

  /// Bumped after an edit so the viewer re-reads instead of showing the text
  /// it loaded before the save.
  int _reloadToken = 0;

  /// Below this the info panel would leave too little room for content, so it
  /// is presented as a sheet over the top instead of as a fixed side panel.
  static const double _sidePanelMinWidth = 820;

  bool get _hasSiblings => widget.files.length > 1;

  /// The Edit action for a shown file, or null when there is nothing sensible
  /// to edit.
  VoidCallback? _editActionFor(FileEntry shown) {
    final target = widget.editEntry ?? shown;
    // An override applies to the single file the preview was opened with; it
    // would be wrong to point it at a sibling.
    if (widget.editEntry != null && shown.path != widget.files.first.path) {
      return null;
    }
    if (!TextDocumentService.canEdit(target)) return null;
    return () async {
      final saved = await openTextEditor(context, target);
      if (saved && mounted) setState(() => _reloadToken++);
    };
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.files.length - 1);
    _pageController = PageController(initialPage: _index);
    // The strip only earns its space when there is something to move between.
    _stripOpen = _hasSiblings;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _goTo(int next) {
    if (next < 0 || next >= widget.files.length || next == _index) return;
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _jump(int delta) => _goTo(_index + delta);

  Future<void> _toggleInfo() async {
    final wide = MediaQuery.sizeOf(context).width >= _sidePanelMinWidth;
    if (wide) {
      setState(() => _infoOpen = !_infoOpen);
      return;
    }
    // Narrow window: show the same panel as a right-hand sheet.
    await showShadSheet<void>(
      context: context,
      side: ShadSheetSide.right,
      builder: (ctx) => ShadSheet(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: EdgeInsets.zero,
        // The sheet sizes to its child, but the panel's scroll area is an
        // Expanded and so needs a bounded height. A right-side sheet should
        // span the window anyway.
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height,
          child: PreviewInfoPanel(
            file: widget.files[_index],
            onClose: () => Navigator.of(ctx).maybePop(),
          ),
        ),
      ),
    );
    // Restore focus so the arrow keys keep working after the sheet closes.
    if (mounted) _focusNode.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.space:
        _jump(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowUp:
        _jump(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyI:
        _toggleInfo();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        if (_hasSiblings) setState(() => _stripOpen = !_stripOpen);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final current = widget.files[_index];
    final wide = MediaQuery.sizeOf(context).width >= _sidePanelMinWidth;
    final showSidePanel = _infoOpen && wide;

    return ColoredBox(
      color: colors.background,
      child: SafeArea(
        child: Focus(
          autofocus: true,
          focusNode: _focusNode,
          onKeyEvent: _onKey,
          child: Column(
            children: [
              _TopBar(
                file: current,
                index: _index,
                total: widget.files.length,
                infoOpen: showSidePanel,
                stripOpen: _stripOpen,
                onPrev: _index > 0 ? () => _jump(-1) : null,
                onNext:
                    _index < widget.files.length - 1 ? () => _jump(1) : null,
                onToggleInfo: _toggleInfo,
                onToggleStrip: _hasSiblings
                    ? () => setState(() => _stripOpen = !_stripOpen)
                    : null,
                onOpenExternally: () => openPathExternally(current.path),
                onClose: () => Navigator.of(context).maybePop(),
              ),
              const ShadSeparator.horizontal(
                  margin: EdgeInsets.zero, thickness: 1),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      // Tells each viewer's floating toolbar how much room the
                      // filmstrip is taking, so it never sits under it.
                      child: PreviewInsets(
                        bottom: _stripOpen ? PreviewFilmstrip.height : 0,
                        child: PageView.builder(
                          controller: _pageController,
                          itemCount: widget.files.length,
                          onPageChanged: (i) => setState(() => _index = i),
                          itemBuilder: (_, i) => PreviewViewerHost(
                            key: ValueKey(
                              '${widget.files[i].path}#$_reloadToken',
                            ),
                            file: widget.files[i],
                            isActive: i == _index,
                            onEdit: _editActionFor(widget.files[i]),
                          ),
                        ),
                      ),
                    ),
                    if (showSidePanel)
                      PreviewInfoPanel(
                        file: current,
                        onClose: () => setState(() => _infoOpen = false),
                      ),
                  ],
                ),
              ),
              if (_stripOpen && _hasSiblings)
                PreviewFilmstrip(
                  files: widget.files,
                  index: _index,
                  onSelect: _goTo,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Persistent header: identity on the left, position and actions on the right.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.file,
    required this.index,
    required this.total,
    required this.infoOpen,
    required this.stripOpen,
    required this.onPrev,
    required this.onNext,
    required this.onToggleInfo,
    required this.onToggleStrip,
    required this.onOpenExternally,
    required this.onClose,
  });

  final FileEntry file;
  final int index;
  final int total;
  final bool infoOpen;
  final bool stripOpen;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onToggleInfo;
  final VoidCallback? onToggleStrip;
  final VoidCallback onOpenExternally;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final ext = previewExtLabel(file);
    return Container(
      height: 52,
      color: colors.muted,
      // The preview fills the window, so while it is open this bar *is* the
      // window's title bar: it has to be draggable and has to clear whatever
      // buttons the OS draws over the content, or the window is stuck and the
      // Back button sits under the macOS traffic lights.
      child: WindowTitleBar(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _bar(context, colors, ext),
        ),
      ),
    );
  }

  Widget _bar(BuildContext context, ShadColorScheme colors, String ext) {
    return LayoutBuilder(
      builder: (_, c) {
        // Shed the least useful things first as the window narrows: the
        // format/size badges, then the sibling counter.
        final showBadges = c.maxWidth >= 560;
        final showCounter = c.maxWidth >= 420 && total > 1;
        return Row(
          children: [
            _BarButton(
              icon: LucideIcons.arrowLeft,
              tooltip: 'Back (Esc)',
              onPressed: onClose,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      file.name,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colors.foreground,
                      ),
                    ),
                  ),
                  if (showBadges) ...[
                    const SizedBox(width: 8),
                    if (ext.isNotEmpty) ...[
                      ShadBadge.secondary(child: Text(ext)),
                      const SizedBox(width: 4),
                    ],
                    ShadBadge.outline(
                      child: Text(formatPreviewBytes(file.size)),
                    ),
                  ],
                ],
              ),
            ),
            if (total > 1) ...[
              _BarButton(
                icon: LucideIcons.chevronLeft,
                tooltip: 'Previous (←)',
                onPressed: onPrev,
              ),
              if (showCounter)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '${index + 1} / $total',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: colors.mutedForeground,
                    ),
                  ),
                ),
              _BarButton(
                icon: LucideIcons.chevronRight,
                tooltip: 'Next (→)',
                onPressed: onNext,
              ),
              const SizedBox(width: 4),
            ],
            if (onToggleStrip != null)
              _BarButton(
                icon: LucideIcons.galleryHorizontalEnd,
                tooltip:
                    stripOpen ? 'Hide filmstrip (F)' : 'Show filmstrip (F)',
                selected: stripOpen,
                onPressed: onToggleStrip,
              ),
            _BarButton(
              icon: LucideIcons.info,
              tooltip: 'Info (I)',
              selected: infoOpen,
              onPressed: onToggleInfo,
            ),
            _BarButton(
              icon: LucideIcons.externalLink,
              tooltip: 'Open in external app',
              onPressed: onOpenExternally,
            ),
            _BarButton(
              icon: LucideIcons.x,
              tooltip: 'Close (Esc)',
              onPressed: onClose,
            ),
          ],
        );
      },
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return ShadTooltip(
      builder: (_) => Text(tooltip, style: const TextStyle(fontSize: 11.5)),
      child: ShadIconButton.ghost(
        width: 32,
        height: 32,
        padding: EdgeInsets.zero,
        iconSize: 17,
        enabled: onPressed != null,
        onPressed: onPressed,
        backgroundColor: selected ? colors.accent : null,
        foregroundColor: selected ? colors.primary : colors.mutedForeground,
        icon: Icon(icon),
      ),
    );
  }
}
