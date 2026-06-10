class WorkflowStep {
  WorkflowStep({
    required this.name,
    required this.promptTemplate,
    this.modelOverride,
  });

  String name;
  String promptTemplate;
  String? modelOverride;

  Map<String, dynamic> toJson() => {
        'name': name,
        'prompt': promptTemplate,
        if (modelOverride != null) 'model': modelOverride,
      };

  factory WorkflowStep.fromJson(Map<String, dynamic> json) => WorkflowStep(
        name: json['name'] as String? ?? 'Step',
        promptTemplate: json['prompt'] as String? ?? '',
        modelOverride: json['model'] as String?,
      );
}
