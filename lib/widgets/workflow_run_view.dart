import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:provider/provider.dart';

import '../providers/workflow_provider.dart';
import '../theme.dart';

class WorkflowRunView extends StatelessWidget {
  const WorkflowRunView({super.key});

  @override
  Widget build(BuildContext context) {
    final wf = context.watch<WorkflowProvider>();
    final palette = AppColors.of(context);
    final w = wf.runningWorkflow;
    if (w == null) return const SizedBox.shrink();
    final results = wf.runResults;

    return Container(
      color: palette.headerBg,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Run: ${w.name}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: palette.text,
                ),
              ),
              const Spacer(),
              if (wf.running) const CupertinoActivityIndicator(radius: 8),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: results.length,
              itemBuilder: (_, i) {
                final r = results[i];
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: palette.cardBg,
                    border: Border.all(color: palette.divider),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            r.done
                                ? (r.error == null
                                    ? CupertinoIcons.check_mark_circled_solid
                                    : CupertinoIcons
                                        .exclamationmark_circle_fill)
                                : CupertinoIcons.circle,
                            size: 14,
                            color: r.error != null
                                ? palette.danger
                                : (r.done
                                    ? palette.success
                                    : palette.subtleText),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${i + 1}. ${r.name}',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                              color: palette.text,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SelectionArea(
                        child: Text(
                          r.error != null
                              ? '[error] ${r.error}'
                              : r.output.toString(),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: palette.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
