import 'package:flutter/foundation.dart';

import '../models/file_entry.dart';
import '../models/workflow.dart';
import '../models/workflow_step.dart';
import '../services/file_service.dart';
import '../services/llm/llm_client.dart';
import '../services/settings_store.dart';
import '../services/workflow_runner.dart';

class RunStepResult {
  RunStepResult({required this.name});
  final String name;
  final StringBuffer output = StringBuffer();
  bool done = false;
  String? error;
}

class WorkflowProvider extends ChangeNotifier {
  WorkflowProvider(this._store, this._fileService);

  final SettingsStore _store;
  final FileService _fileService;

  List<Workflow> _workflows = [];
  bool _loaded = false;

  // Run state
  Workflow? _runningWorkflow;
  List<RunStepResult> _runResults = [];
  bool _running = false;

  List<Workflow> get workflows => _workflows;
  bool get loaded => _loaded;
  Workflow? get runningWorkflow => _runningWorkflow;
  List<RunStepResult> get runResults => _runResults;
  bool get running => _running;

  Future<void> load() async {
    _workflows = await _store.loadWorkflows();
    if (_workflows.isEmpty) {
      _workflows = _seedTemplates();
      await _store.saveWorkflows(_workflows);
    }
    _loaded = true;
    notifyListeners();
  }

  List<Workflow> _seedTemplates() {
    return [
      Workflow(
        id: 'tmpl-summarize',
        name: 'Summarize file',
        description: 'One-step summary of a selected text file.',
        steps: [
          WorkflowStep(
            name: 'Summarize',
            promptTemplate:
                'Summarize the following file in 5 bullet points.\n\nFile: {file_name}\n\n{file_content}',
          ),
        ],
      ),
      Workflow(
        id: 'tmpl-summarize-translate',
        name: 'Summarize → Translate (FR)',
        description: 'Summarize the file, then translate the summary to French.',
        steps: [
          WorkflowStep(
            name: 'Summarize',
            promptTemplate:
                'Summarize the following file in 5 bullet points.\n\n{file_content}',
          ),
          WorkflowStep(
            name: 'Translate to French',
            promptTemplate:
                'Translate the following bullet summary to French. Return only the translation.\n\n{prev}',
          ),
        ],
      ),
    ];
  }

  Future<void> save() async {
    await _store.saveWorkflows(_workflows);
    notifyListeners();
  }

  Future<void> upsert(Workflow w) async {
    final idx = _workflows.indexWhere((x) => x.id == w.id);
    if (idx == -1) {
      _workflows.add(w);
    } else {
      _workflows[idx] = w;
    }
    await save();
  }

  Future<void> delete(String id) async {
    _workflows.removeWhere((w) => w.id == id);
    await save();
  }

  Future<void> run({
    required Workflow workflow,
    required LlmClient llm,
    required String model,
    required double temperature,
    FileEntry? selectedFile,
  }) async {
    if (_running) return;
    _running = true;
    _runningWorkflow = workflow;
    _runResults = workflow.steps
        .map((s) => RunStepResult(name: s.name))
        .toList(growable: false);
    notifyListeners();

    final runner = WorkflowRunner(
      llm: llm,
      fileService: _fileService,
    );

    try {
      await for (final ev in runner.run(
        workflow: workflow,
        defaultModel: model,
        temperature: temperature,
        selectedFile: selectedFile,
      )) {
        final r = _runResults[ev.stepIndex];
        if (ev.error != null) {
          r.error = ev.error;
          r.done = true;
        } else if (ev.done) {
          r.done = true;
        } else {
          r.output.write(ev.token);
        }
        notifyListeners();
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }
}
