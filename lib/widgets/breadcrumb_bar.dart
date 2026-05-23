import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../providers/browser_provider.dart';
import '../theme.dart';

class BreadcrumbBar extends StatelessWidget {
  const BreadcrumbBar({super.key});

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    final path = browser.currentPath;

    return SizedBox(
      height: 44,
      child: path.isEmpty
          ? const SizedBox.shrink()
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: _buildCrumbs(context, browser, path)),
            ),
    );
  }

  List<Widget> _buildCrumbs(
    BuildContext context,
    BrowserProvider browser,
    String path,
  ) {
    final palette = AppColors.of(context);
    final parts = p.split(path);
    final List<Widget> chips = [];
    String acc = '';
    for (var i = 0; i < parts.length; i++) {
      acc = i == 0 ? parts[i] : p.join(acc, parts[i]);
      final segment = parts[i].isEmpty ? '/' : parts[i];
      final target = acc;
      final isLast = i == parts.length - 1;
      chips.add(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => browser.navigateTo(target),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(
                segment,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                  color: isLast ? palette.text : palette.subtleText,
                ),
              ),
            ),
          ),
        ),
      );
      if (!isLast) {
        chips.add(Icon(
          CupertinoIcons.chevron_right,
          size: 11,
          color: palette.subtleText,
        ));
      }
    }
    return chips;
  }
}
