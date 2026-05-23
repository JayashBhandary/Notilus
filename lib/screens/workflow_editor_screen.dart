import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../models/workflow.dart';
import '../models/workflow_step.dart';
import '../providers/workflow_provider.dart';
import '../theme.dart';

class WorkflowEditorScreen extends StatefulWidget {
  const WorkflowEditorScreen({super.key, this.workflow});
  final Workflow? workflow;

  @override
  State<WorkflowEditorScreen> createState() => _WorkflowEditorScreenState();
}

class _WorkflowEditorScreenState extends State<WorkflowEditorScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _descCtrl;
  late List<_StepCtrls> _stepCtrls;
  late String _id;

  @override
  void initState() {
    super.initState();
    final w = widget.workflow;
    _id = w?.id ??
        'wf-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    _nameCtrl = TextEditingController(text: w?.name ?? '');
    _descCtrl = TextEditingController(text: w?.description ?? '');
    _stepCtrls = (w?.steps ?? [])
        .map((s) => _StepCtrls(name: s.name, prompt: s.promptTemplate))
        .toList();
    if (_stepCtrls.isEmpty) _stepCtrls.add(_StepCtrls(name: 'Step 1'));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    for (final c in _stepCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final w = Workflow(
      id: _id,
      name: _nameCtrl.text.trim().isEmpty ? 'Untitled' : _nameCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      steps: _stepCtrls
          .map((c) => WorkflowStep(
                name: c.nameCtrl.text.trim().isEmpty
                    ? 'Step'
                    : c.nameCtrl.text.trim(),
                promptTemplate: c.promptCtrl.text,
              ))
          .toList(),
    );
    await context.read<WorkflowProvider>().upsert(w);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete workflow?'),
        content: const Text('This cannot be undone.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    if (widget.workflow == null) {
      Navigator.of(context).pop();
      return;
    }
    await context.read<WorkflowProvider>().delete(widget.workflow!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.workflow == null;
    final palette = AppColors.of(context);
    return CupertinoPageScaffold(
      backgroundColor: palette.scaffoldBg,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
        middle: Text(isNew ? 'New Workflow' : 'Edit Workflow'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isNew)
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                onPressed: _confirmDelete,
                child: Icon(
                  CupertinoIcons.trash,
                  color: palette.danger,
                  size: 20,
                ),
              ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              onPressed: _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Card(
              palette: palette,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _LabeledField(
                    label: 'Name',
                    palette: palette,
                    child: CupertinoTextField(
                      controller: _nameCtrl,
                      placeholder: 'Workflow name',
                      style: TextStyle(fontSize: 13, color: palette.text),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: palette.cardBg,
                        border: Border.all(color: palette.divider),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _LabeledField(
                    label: 'Description',
                    palette: palette,
                    child: CupertinoTextField(
                      controller: _descCtrl,
                      placeholder: 'Optional',
                      style: TextStyle(fontSize: 13, color: palette.text),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: palette.cardBg,
                        border: Border.all(color: palette.divider),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: palette.brightness == Brightness.dark
                    ? const Color(0xFF3A330F)
                    : const Color(0xFFFFF8E1),
                border: Border.all(
                  color: palette.brightness == Brightness.dark
                      ? const Color(0xFF6B5800)
                      : const Color(0xFFE6D98C),
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Placeholders: {file_content}, {file_name}, {file_path}, '
                '{prev}, {step_1}, {step_2}, …',
                style: TextStyle(
                  fontSize: 11,
                  color: palette.brightness == Brightness.dark
                      ? const Color(0xFFE6D98C)
                      : const Color(0xFF6B5800),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ..._stepCtrls.asMap().entries.map((entry) {
              final i = entry.key;
              final c = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _Card(
                  palette: palette,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Step ${i + 1}',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              color: palette.text,
                            ),
                          ),
                          const Spacer(),
                          CupertinoButton(
                            padding: const EdgeInsets.all(4),
                            onPressed: _stepCtrls.length <= 1
                                ? null
                                : () => setState(() {
                                      c.dispose();
                                      _stepCtrls.removeAt(i);
                                    }),
                            child: Icon(
                              CupertinoIcons.minus_circle,
                              size: 18,
                              color: _stepCtrls.length <= 1
                                  ? palette.subtleText
                                      .withValues(alpha: 0.4)
                                  : palette.danger,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      _LabeledField(
                        label: 'Step name',
                        palette: palette,
                        child: CupertinoTextField(
                          controller: c.nameCtrl,
                          style: TextStyle(
                            fontSize: 13,
                            color: palette.text,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: palette.cardBg,
                            border: Border.all(color: palette.divider),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _LabeledField(
                        label: 'Prompt template',
                        palette: palette,
                        child: CupertinoTextField(
                          controller: c.promptCtrl,
                          minLines: 4,
                          maxLines: 12,
                          style: TextStyle(
                            fontSize: 13,
                            fontFamily: 'Menlo',
                            color: palette.text,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: palette.cardBg,
                            border: Border.all(color: palette.divider),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 10),
              onPressed: () => setState(() => _stepCtrls
                  .add(_StepCtrls(name: 'Step ${_stepCtrls.length + 1}'))),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(CupertinoIcons.add_circled, size: 18),
                  SizedBox(width: 6),
                  Text('Add step', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.palette});
  final Widget child;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.child,
    required this.palette,
  });
  final String label;
  final Widget child;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: palette.subtleText,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

class _StepCtrls {
  _StepCtrls({String name = '', String prompt = ''})
      : nameCtrl = TextEditingController(text: name),
        promptCtrl = TextEditingController(text: prompt);

  final TextEditingController nameCtrl;
  final TextEditingController promptCtrl;

  void dispose() {
    nameCtrl.dispose();
    promptCtrl.dispose();
  }
}
