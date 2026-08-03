import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../providers/browser_provider.dart';
import '../providers/search_provider.dart';
import '../theme.dart';

/// Lets the Cmd/Ctrl+F command reach the live search field. Follows the same
/// pattern as `pathStatusBarKey`: the field is buried a few layers down inside
/// the layout, and a shortcut needs to focus *that* instance.
final GlobalKey<FolderSearchBarState> folderSearchKey =
    GlobalKey<FolderSearchBarState>();

/// Search field for the current folder subtree.
///
/// Filename matching is on by default; the toggle also greps file contents.
/// Both run in Rust over a parallel walk, streaming hits as they're found, so
/// the field stays responsive on a large tree.
class FolderSearchBar extends StatefulWidget {
  const FolderSearchBar({super.key});

  @override
  State<FolderSearchBar> createState() => FolderSearchBarState();
}

class FolderSearchBarState extends State<FolderSearchBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'FolderSearch');

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Focuses the field and selects whatever is already in it, so Cmd+F on an
  /// active query replaces it by typing rather than appending.
  void focusSearch() {
    _focusNode.requestFocus();
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final search = context.watch<SearchProvider>();
    final browser = context.watch<BrowserProvider>();

    return Row(
      children: [
        Expanded(
          child: CupertinoSearchTextField(
            controller: _controller,
            focusNode: _focusNode,
            placeholder: 'Search this folder',
            style: TextStyle(fontSize: 12, color: palette.text),
            backgroundColor: palette.contentBg,
            onChanged: (value) =>
                search.setQuery(value, root: browser.currentPath),
            onSuffixTap: () {
              _controller.clear();
              search.clear();
            },
          ),
        ),
        const SizedBox(width: 8),
        _ContentToggle(
          enabled: search.searchContent,
          palette: palette,
          onTap: () => search.setSearchContent(!search.searchContent),
        ),
        if (search.isRunning) ...[
          const SizedBox(width: 8),
          const CupertinoActivityIndicator(radius: 7),
        ],
      ],
    );
  }
}

/// Toggles content search. Off by default: reading every file is much more
/// expensive than matching names, and most searches are for a filename.
class _ContentToggle extends StatelessWidget {
  const _ContentToggle({
    required this.enabled,
    required this.palette,
    required this.onTap,
  });

  final bool enabled;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.doc_text_search,
            size: 14,
            color: enabled ? palette.accent : palette.subtleText,
          ),
          const SizedBox(width: 4),
          Text(
            'Contents',
            style: TextStyle(
              fontSize: 11,
              color: enabled ? palette.accent : palette.subtleText,
              fontWeight: enabled ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// Results list, shown in place of the folder listing while a query is active.
class SearchResultsView extends StatelessWidget {
  const SearchResultsView({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final search = context.watch<SearchProvider>();
    final browser = context.read<BrowserProvider>();
    final hits = search.hits;

    if (hits.isEmpty) {
      return Center(
        child: Text(
          search.isRunning
              ? 'Searching…'
              : 'No matches for "${search.query}"',
          style: TextStyle(fontSize: 13, color: palette.subtleText),
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: palette.headerBg,
          child: Text(
            '${hits.length} result${hits.length == 1 ? '' : 's'}'
            '${search.truncated ? ' (showing the first ${hits.length})' : ''}'
            '${search.isRunning ? ' so far…' : ''}',
            style: TextStyle(fontSize: 11, color: palette.subtleText),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: hits.length,
            itemBuilder: (context, i) {
              final hit = hits[i];
              return _HitRow(
                name: hit.entry.name,
                path: hit.entry.path,
                preview: hit.preview,
                line: hit.line?.toInt(),
                palette: palette,
                // Opening a result reveals it in its own folder, which is what
                // makes a result actionable rather than just informative.
                onTap: () => browser.revealPath(hit.entry.path),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HitRow extends StatelessWidget {
  const _HitRow({
    required this.name,
    required this.path,
    required this.preview,
    required this.line,
    required this.palette,
    required this.onTap,
  });

  final String name;
  final String path;
  final String? preview;
  final int? line;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  CupertinoIcons.doc,
                  size: 14,
                  color: palette.subtleText,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: palette.text),
                  ),
                ),
                if (line != null)
                  Text(
                    'line $line',
                    style: TextStyle(fontSize: 10, color: palette.subtleText),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 1),
              child: Text(
                path,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: palette.subtleText),
              ),
            ),
            if (preview != null && preview!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 3),
                child: Text(
                  preview!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 10,
                    color: palette.subtleText,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
