import 'workflow_step.dart';

class Workflow {
  Workflow({
    required this.id,
    required this.name,
    this.description = '',
    List<WorkflowStep>? steps,
  }) : steps = steps ?? <WorkflowStep>[];

  final String id;
  String name;
  String description;
  List<WorkflowStep> steps;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory Workflow.fromJson(Map<String, dynamic> json) => Workflow(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Untitled',
        description: json['description'] as String? ?? '',
        steps: (json['steps'] as List? ?? [])
            .map((e) => WorkflowStep.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
