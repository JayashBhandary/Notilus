import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../providers/settings_provider.dart';
import '../services/llm/llm_client.dart';
import '../theme.dart';
import '../widgets/shad_spinner.dart';

/// Shows the settings as a centered modal dialog. Settings hold only a handful
/// of controls, so a popup is lighter than a dedicated page. Presented with no
/// transition — animating the barrier + card every open is wasted GPU work,
/// hence the empty [animateIn]/[animateOut] effect lists.
Future<void> showSettingsDialog(BuildContext context) {
  return showShadDialog<void>(
    context: context,
    barrierColor: const Color(0x66000000),
    barrierLabel: 'Settings',
    animateIn: const [],
    animateOut: const [],
    builder: (_) => const SettingsDialog(),
  );
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late TextEditingController _hostCtrl;
  late TextEditingController _apiKeyCtrl;
  late TextEditingController _baseUrlCtrl;
  late TextEditingController _destCtrl;
  late ShadSliderController _tempCtrl;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    _hostCtrl = TextEditingController(text: settings.host);
    _apiKeyCtrl =
        TextEditingController(text: settings.apiKeyFor(settings.provider));
    _baseUrlCtrl = TextEditingController(text: settings.compatBaseUrl);
    _destCtrl = TextEditingController(text: settings.transferDestination);
    _tempCtrl = ShadSliderController(initialValue: settings.temperature);
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _destCtrl.dispose();
    _tempCtrl.dispose();
    super.dispose();
  }

  Future<void> _selectProvider(
    SettingsProvider settings,
    LlmProviderKind kind,
  ) async {
    await settings.setProvider(kind);
    if (!mounted) return;
    setState(() {
      _hostCtrl.text = settings.host;
      _apiKeyCtrl.text = settings.apiKeyFor(kind);
      _baseUrlCtrl.text = settings.compatBaseUrl;
    });
  }

  Future<void> _saveAndTest(SettingsProvider settings) async {
    setState(() => _testing = true);
    final p = settings.provider;
    switch (p) {
      case LlmProviderKind.ollama:
        await settings.setHost(_hostCtrl.text.trim());
        break;
      case LlmProviderKind.anthropic:
      case LlmProviderKind.gemini:
      case LlmProviderKind.openai:
        await settings.setApiKey(p, _apiKeyCtrl.text);
        break;
      case LlmProviderKind.openaiCompat:
        await settings.setCompatBaseUrl(_baseUrlCtrl.text);
        await settings.setApiKey(p, _apiKeyCtrl.text);
        break;
    }
    await settings.refreshModelsFor(p);
    if (mounted) setState(() => _testing = false);
  }

  String _unconfiguredHint(LlmProviderKind kind) {
    switch (kind) {
      case LlmProviderKind.openaiCompat:
        return 'Enter a base URL';
      default:
        return 'Enter an API key';
    }
  }

  List<Widget> _providerFields(SettingsProvider settings) {
    switch (settings.provider) {
      case LlmProviderKind.ollama:
        return [
          _LabeledField(
            label: 'Host URL',
            child: ShadInput(
              controller: _hostCtrl,
              placeholder: const Text('http://localhost:11434'),
            ),
          ),
        ];
      case LlmProviderKind.anthropic:
        return [
          _LabeledField(
            label: 'Anthropic API key',
            child: ShadInput(
              controller: _apiKeyCtrl,
              placeholder: const Text('sk-ant-…'),
              obscureText: true,
            ),
          ),
        ];
      case LlmProviderKind.gemini:
        return [
          _LabeledField(
            label: 'Google AI API key',
            child: ShadInput(
              controller: _apiKeyCtrl,
              placeholder: const Text('AIza…'),
              obscureText: true,
            ),
          ),
        ];
      case LlmProviderKind.openai:
        return [
          _LabeledField(
            label: 'OpenAI API key',
            child: ShadInput(
              controller: _apiKeyCtrl,
              placeholder: const Text('sk-…'),
              obscureText: true,
            ),
          ),
        ];
      case LlmProviderKind.openaiCompat:
        return [
          _LabeledField(
            label: 'Base URL (OpenAI-compatible)',
            child: ShadInput(
              controller: _baseUrlCtrl,
              placeholder: const Text('http://localhost:1234/v1'),
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'API key (optional)',
            child: ShadInput(
              controller: _apiKeyCtrl,
              placeholder: const Text('Leave empty if the server has no auth'),
              obscureText: true,
            ),
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final theme = ShadTheme.of(context);
    final colors = theme.colorScheme;
    final palette = AppColors.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return ShadDialog(
      title: const Text('Settings'),
      constraints: BoxConstraints(maxWidth: 460, maxHeight: maxHeight),
      scrollable: true,
      titlePinned: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Section(
            title: 'Appearance',
            children: [
              _ThemeSelector(
                current: settings.themeMode,
                onChanged: settings.setThemeMode,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'File Transfer',
            children: [
              // The label/sublabel slots are deliberately unused. They put the
              // toggle on the left, and the only way to move it right is
              // `direction: rtl` — which ShadSwitch also applies to the thumb's
              // own stack, parking the thumb on the left while the track still
              // reads as on. An explicit Row keeps the thumb correct.
              _SwitchRow(
                label: 'Receive in the background',
                sublabel: 'Closing the window keeps Notilus in the tray so '
                    'friends can still send you files.',
                value: settings.backgroundReception,
                onChanged: settings.setBackgroundReception,
              ),
              const SizedBox(height: 14),
              _SwitchRow(
                label: 'Prefer local network',
                sublabel: 'When a contact is on the same network, send '
                    'directly over the LAN (faster, no server). Falls back '
                    'automatically otherwise.',
                value: settings.preferLocalNetwork,
                onChanged: settings.setPreferLocalNetwork,
              ),
              const SizedBox(height: 12),
              _LabeledField(
                label: 'Save received files to',
                child: ShadInput(
                  controller: _destCtrl,
                  placeholder: const Text('~/Downloads/Notilus (default)'),
                  onSubmitted: settings.setTransferDestination,
                  onPressedOutside: (_) =>
                      settings.setTransferDestination(_destCtrl.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'AI Provider',
            children: [
              // Five providers do not fit a 460px dialog side by side, so the
              // tab bar scrolls rather than squeezing the labels.
              ShadTabs<LlmProviderKind>(
                value: settings.provider,
                scrollable: true,
                gap: 0,
                onChanged: (v) => _selectProvider(settings, v),
                tabs: [
                  for (final k in LlmProviderKind.values)
                    ShadTab(
                      value: k,
                      child: Text(
                        k.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              ..._providerFields(settings),
              const SizedBox(height: 12),
              Row(
                children: [
                  ShadButton(
                    onPressed: _testing ? null : () => _saveAndTest(settings),
                    child: _testing
                        ? ShadSpinner(
                            size: 16,
                            color: colors.primaryForeground,
                          )
                        : const Text(
                            'Save & Test',
                            style: TextStyle(fontSize: 13),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    settings.connected
                        ? LucideIcons.circleCheck
                        : LucideIcons.circleX,
                    color: settings.connected
                        ? palette.success
                        : colors.destructive,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      settings.connected
                          ? 'Connected • ${settings.availableModels.length} models'
                          : settings.isConfigured(settings.provider)
                              ? 'Not connected'
                              : _unconfiguredHint(settings.provider),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Default Model',
            children: [
              if (settings.availableModels.isEmpty)
                Text(
                  settings.isConfigured(settings.provider)
                      ? 'No models available. Check the '
                          '${settings.provider.label} connection above.'
                      : 'Configure ${settings.provider.label} above '
                          'to load its models.',
                  style: TextStyle(
                    color: colors.mutedForeground,
                    fontSize: 12,
                  ),
                )
              else
                // ShadSelect is uncontrolled — it reads initialValue once. The
                // key remounts it when the provider (and therefore the model)
                // changes underneath, so the trigger never shows a stale model.
                ShadSelect<String>(
                  key: ValueKey('${settings.provider}:${settings.model}'),
                  initialValue: settings.model,
                  placeholder: const Text('Pick a model'),
                  maxHeight: 240,
                  onChanged: (v) {
                    if (v != null) settings.setModel(v);
                  },
                  selectedOptionBuilder: (_, value) =>
                      Text(value, style: const TextStyle(fontSize: 13)),
                  options: [
                    for (final m in settings.availableModels)
                      ShadOption(
                        value: m,
                        child: Text(m, style: const TextStyle(fontSize: 13)),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Generation',
            children: [
              Row(
                children: [
                  Text(
                    'Temperature',
                    style: TextStyle(fontSize: 13, color: colors.foreground),
                  ),
                  const Spacer(),
                  Text(
                    settings.temperature.toStringAsFixed(2),
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.mutedForeground,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // No `divisions` here: ShadSlider paints one tick mark per
              // division, so the 30 steps this control had under Cupertino
              // turn the track into a barcode. Snap in the callback instead —
              // same 0.05 granularity, plain track.
              ShadSlider(
                controller: _tempCtrl,
                min: 0.0,
                max: 1.5,
                onChanged: (v) => settings.setTemperature((v * 20).round() / 20),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ThemeSelector extends StatelessWidget {
  const _ThemeSelector({required this.current, required this.onChanged});

  final AppThemeMode current;
  final ValueChanged<AppThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    // ShadTabs hands each tab an unbounded width and then squeezes the result
    // into a third of the row, so a chip that doesn't fit overflows instead of
    // ellipsising. Three icon+label chips need ~300px; below that the labels are
    // dropped rather than clipped.
    return LayoutBuilder(
      builder: (ctx, c) {
        // Normalised by the OS text scale for the same reason as the toolbar:
        // the 300px figure assumes 13px labels.
        final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
        final showLabels = !c.maxWidth.isFinite ||
            c.maxWidth / (scale <= 0 ? 1 : scale) >= 300;
        return ShadTabs<AppThemeMode>(
          value: current,
          gap: 0,
          onChanged: onChanged,
          tabs: [
            ShadTab(
              value: AppThemeMode.system,
              child: _ThemeChip(
                icon: LucideIcons.settings,
                label: 'System',
                showLabel: showLabels,
              ),
            ),
            ShadTab(
              value: AppThemeMode.light,
              child: _ThemeChip(
                icon: LucideIcons.sun,
                label: 'Light',
                showLabel: showLabels,
              ),
            ),
            ShadTab(
              value: AppThemeMode.dark,
              child: _ThemeChip(
                icon: LucideIcons.moon,
                label: 'Dark',
                showLabel: showLabels,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ThemeChip extends StatelessWidget {
  const _ThemeChip({
    required this.icon,
    required this.label,
    this.showLabel = true,
  });
  final IconData icon;
  final String label;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    if (!showLabel) {
      return ShadTooltip(
        builder: (_) => Text(label),
        child: Icon(icon, size: 14),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ],
    );
  }
}

/// Label + description on the left, [ShadSwitch] on the right.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.sublabel,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String sublabel;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 13, color: colors.foreground),
              ),
              const SizedBox(height: 2),
              Text(
                sublabel,
                style: TextStyle(
                  fontSize: 11.5,
                  color: colors.mutedForeground,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ShadSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.5,
              fontWeight: FontWeight.w600,
              color: colors.mutedForeground,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: colors.mutedForeground),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}
