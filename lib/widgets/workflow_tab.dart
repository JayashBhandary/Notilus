import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../models/workflow.dart';
import '../providers/browser_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/workflow_provider.dart';
import '../screens/workflow_editor_screen.dart';
import '../theme.dart';
import 'workflow_run_view.dart';

class WorkflowTab extends StatelessWidget {
  const WorkflowTab({super.key});

  @override
  Widget build(BuildContext context) {
    final wf = context.watch<WorkflowProvider>();
    final browser = context.watch<BrowserProvider>();
    final settings = context.watch<SettingsProvider>();
    final palette = AppColors.of(context);
    final selection = browser.primarySelection;

    return ColoredBox(
      color: palette.contentBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
            child: Row(
              children: [
                Text(
                  'Workflows',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: palette.text,
                  ),
                ),
                const Spacer(),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  onPressed: () => _openEditor(context, null),
                  child: Icon(
                    CupertinoIcons.add,
                    size: 18,
                    color: palette.accent,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              selection == null
                  ? 'No file selected — workflows will run without {file_content}.'
                  : 'Selected: ${selection.name}',
              style: TextStyle(
                fontSize: 11,
                color: palette.subtleText,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: wf.workflows.isEmpty
                ? Center(
                    child: Text(
                      'No workflows yet',
                      style: TextStyle(
                        color: palette.subtleText,
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: wf.workflows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (_, i) {
                      final w = wf.workflows[i];
                      final running =
                          wf.running && wf.runningWorkflow?.id == w.id;
                      return _WorkflowRow(
                        workflow: w,
                        running: running,
                        canRun: !wf.running && settings.model != null,
                        onEdit: () => _openEditor(context, w),
                        onRun: () => wf.run(
                          workflow: w,
                          host: settings.host,
                          model: settings.model!,
                          temperature: settings.temperature,
                          selectedFile: selection,
                        ),
                      );
                    },
                  ),
          ),
          if (wf.runningWorkflow != null)
            Container(height: 1, color: palette.divider),
          if (wf.runningWorkflow != null)
            const Expanded(child: WorkflowRunView()),
        ],
      ),
    );
  }

  void _openEditor(BuildContext context, Workflow? w) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => WorkflowEditorScreen(workflow: w),
      ),
    );
  }
}

class _WorkflowRow extends StatefulWidget {
  const _WorkflowRow({
    required this.workflow,
    required this.running,
    required this.canRun,
    required this.onEdit,
    required this.onRun,
  });

  final Workflow workflow;
  final bool running;
  final bool canRun;
  final VoidCallback onEdit;
  final VoidCallback onRun;

  @override
  State<_WorkflowRow> createState() => _WorkflowRowState();
}

class _WorkflowRowState extends State<_WorkflowRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget.workflow;
    final palette = AppColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        decoration: BoxDecoration(
          color: _hover ? palette.sidebarHover : palette.cardBg,
          border: Border.all(color: palette.divider),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    w.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: palette.text,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${w.steps.length} step${w.steps.length == 1 ? '' : 's'}'
                    '${w.description.isNotEmpty ? ' • ${w.description}' : ''}',
                    style: TextStyle(
                      fontSize: 11,
                      color: palette.subtleText,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.all(4),
              onPressed: widget.onEdit,
              child: Icon(
                CupertinoIcons.pencil,
                size: 16,
                color: palette.subtleText,
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.all(4),
              onPressed:
                  widget.canRun && !widget.running ? widget.onRun : null,
              child: widget.running
                  ? const CupertinoActivityIndicator(radius: 8)
                  : Icon(
                      CupertinoIcons.play_arrow_solid,
                      size: 18,
                      color: widget.canRun
                          ? palette.accent
                          : palette.subtleText.withValues(alpha: 0.4),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
