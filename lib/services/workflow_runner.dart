import 'dart:async';

import '../models/file_entry.dart';
import '../models/workflow.dart';
import 'file_service.dart';
import 'ollama_service.dart';

class StepRunEvent {
  StepRunEvent({
    required this.stepIndex,
    required this.stepName,
    required this.token,
    this.done = false,
    this.error,
  });

  final int stepIndex;
  final String stepName;
  final String token;
  final bool done;
  final String? error;
}

class WorkflowRunner {
  WorkflowRunner({
    required this.ollama,
    required this.fileService,
  });

  final OllamaService ollama;
  final FileService fileService;

  /// Runs a workflow on a (possibly null) selected file, streaming tokens
  /// per step. Step outputs are piped into placeholders of subsequent steps.
  Stream<StepRunEvent> run({
    required Workflow workflow,
    required String defaultModel,
    required double temperature,
    FileEntry? selectedFile,
  }) async* {
    final List<String> outputs = [];

    String? fileContent;
    if (selectedFile != null && !selectedFile.isDirectory) {
      fileContent = await fileService.readTextCapped(selectedFile.path);
    }

    for (var i = 0; i < workflow.steps.length; i++) {
      final step = workflow.steps[i];
      final model = (step.modelOverride?.isNotEmpty ?? false)
          ? step.modelOverride!
          : defaultModel;

      final prompt = _substitute(
        step.promptTemplate,
        fileContent: fileContent,
        fileEntry: selectedFile,
        outputs: outputs,
      );

      final buffer = StringBuffer();
      try {
        await for (final chunk in ollama.generate(
          model: model,
          prompt: prompt,
          temperature: temperature,
        )) {
          buffer.write(chunk);
          yield StepRunEvent(
            stepIndex: i,
            stepName: step.name,
            token: chunk,
          );
        }
      } catch (e) {
        yield StepRunEvent(
          stepIndex: i,
          stepName: step.name,
          token: '',
          done: true,
          error: e.toString(),
        );
        return;
      }

      outputs.add(buffer.toString());
      yield StepRunEvent(
        stepIndex: i,
        stepName: step.name,
        token: '',
        done: true,
      );
    }
  }

  String _substitute(
    String template, {
    String? fileContent,
    FileEntry? fileEntry,
    required List<String> outputs,
  }) {
    var s = template;
    s = s.replaceAll('{file_content}', fileContent ?? '');
    s = s.replaceAll('{file_name}', fileEntry?.name ?? '');
    s = s.replaceAll('{file_path}', fileEntry?.path ?? '');
    if (outputs.isNotEmpty) {
      s = s.replaceAll('{prev}', outputs.last);
    } else {
      s = s.replaceAll('{prev}', '');
    }
    for (var i = 0; i < outputs.length; i++) {
      s = s.replaceAll('{step_${i + 1}}', outputs[i]);
    }
    return s;
  }
}
