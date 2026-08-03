import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../models/file_entry.dart';
import 'preview_common.dart';

/// File metadata, shown *beside* the content rather than over it.
///
/// The previous design put this in a modal popup, so inspecting a value meant
/// hiding the thing it described. As a side panel you can read the dimensions
/// while looking at the image.
class PreviewInfoPanel extends StatefulWidget {
  const PreviewInfoPanel({
    super.key,
    required this.file,
    required this.onClose,
  });

  final FileEntry file;
  final VoidCallback onClose;

  static const double width = 280;

  @override
  State<PreviewInfoPanel> createState() => _PreviewInfoPanelState();
}

class _PreviewInfoPanelState extends State<PreviewInfoPanel> {
  Size? _dims;
  bool _dimsLoaded = false;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _maybeLoadDims();
  }

  @override
  void didUpdateWidget(covariant PreviewInfoPanel old) {
    super.didUpdateWidget(old);
    // The panel stays mounted while the shell pages between siblings, so the
    // dimensions have to be re-read whenever the file underneath changes.
    if (old.file.path != widget.file.path) {
      _dims = null;
      _dimsLoaded = false;
      _copied = false;
      _maybeLoadDims();
    }
  }

  void _maybeLoadDims() {
    if (!widget.file.isImage) return;
    _loadDims(widget.file.path);
  }

  Future<void> _loadDims(String forPath) async {
    try {
      final bytes = await File(forPath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final size = Size(img.width.toDouble(), img.height.toDouble());
      img.dispose();
      codec.dispose();
      // Guard against a slow decode landing after the user has paged on.
      if (!mounted || widget.file.path != forPath) return;
      setState(() {
        _dims = size;
        _dimsLoaded = true;
      });
    } catch (_) {
      if (!mounted || widget.file.path != forPath) return;
      setState(() => _dimsLoaded = true);
    }
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.file.path));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final f = widget.file;
    return Container(
      width: PreviewInfoPanel.width,
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(left: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(
              children: [
                Text(
                  'INFO',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600,
                    color: colors.mutedForeground,
                  ),
                ),
                const Spacer(),
                ShadIconButton.ghost(
                  width: 26,
                  height: 26,
                  padding: EdgeInsets.zero,
                  iconSize: 15,
                  foregroundColor: colors.mutedForeground,
                  onPressed: widget.onClose,
                  icon: const Icon(LucideIcons.x),
                ),
              ],
            ),
          ),
          const ShadSeparator.horizontal(margin: EdgeInsets.zero, thickness: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Field(label: 'Name', value: f.name),
                    _Field(label: 'Kind', value: previewKind(f.extension)),
                    _Field(
                      label: 'Size',
                      value: formatPreviewBytes(f.size, exact: true),
                    ),
                    _Field(
                      label: 'Modified',
                      value: formatPreviewDate(f.modified),
                    ),
                    if (f.isImage)
                      _Field(
                        label: 'Dimensions',
                        value: !_dimsLoaded
                            ? 'reading…'
                            : _dims == null
                                ? 'unknown'
                                : '${_dims!.width.round()} × '
                                    '${_dims!.height.round()} px',
                      ),
                    _Field(label: 'Path', value: f.path, monospace: true),
                    const SizedBox(height: 10),
                    ShadButton.outline(
                      onPressed: _copyPath,
                      size: ShadButtonSize.sm,
                      leading: Icon(
                        _copied ? LucideIcons.check : LucideIcons.copy,
                        size: 14,
                      ),
                      child: Text(_copied ? 'Copied' : 'Copy path'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A stacked label/value pair. Stacked rather than side-by-side because paths
/// are long and the panel is only 280px wide.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: monospace ? 11 : 12.5,
              fontFamily: monospace ? 'Menlo' : null,
              height: 1.4,
              color: colors.foreground,
            ),
          ),
        ],
      ),
    );
  }
}
