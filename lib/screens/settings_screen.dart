import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../services/llm/llm_client.dart';
import '../theme.dart';

/// Shows the settings as a centered modal dialog. Settings hold only a handful
/// of controls, so a popup is lighter than a dedicated page. Presented with no
/// transition — animating the barrier + card every open is wasted GPU work.
Future<void> showSettingsDialog(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Settings',
    barrierColor: const Color(0x66000000),
    transitionDuration: Duration.zero,
    pageBuilder: (_, __, ___) => const SettingsDialog(),
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
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _destCtrl.dispose();
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

  Widget _settingsTextField({
    required TextEditingController controller,
    required String placeholder,
    required AppPalette palette,
    bool obscure = false,
  }) {
    return CupertinoTextField(
      controller: controller,
      placeholder: placeholder,
      obscureText: obscure,
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      style: TextStyle(fontSize: 13, color: palette.text),
    );
  }

  List<Widget> _providerFields(SettingsProvider settings, AppPalette palette) {
    switch (settings.provider) {
      case LlmProviderKind.ollama:
        return [
          _LabeledField(
            label: 'Host URL',
            palette: palette,
            child: _settingsTextField(
              controller: _hostCtrl,
              placeholder: 'http://localhost:11434',
              palette: palette,
            ),
          ),
        ];
      case LlmProviderKind.anthropic:
        return [
          _LabeledField(
            label: 'Anthropic API key',
            palette: palette,
            child: _settingsTextField(
              controller: _apiKeyCtrl,
              placeholder: 'sk-ant-…',
              palette: palette,
              obscure: true,
            ),
          ),
        ];
      case LlmProviderKind.gemini:
        return [
          _LabeledField(
            label: 'Google AI API key',
            palette: palette,
            child: _settingsTextField(
              controller: _apiKeyCtrl,
              placeholder: 'AIza…',
              palette: palette,
              obscure: true,
            ),
          ),
        ];
      case LlmProviderKind.openai:
        return [
          _LabeledField(
            label: 'OpenAI API key',
            palette: palette,
            child: _settingsTextField(
              controller: _apiKeyCtrl,
              placeholder: 'sk-…',
              palette: palette,
              obscure: true,
            ),
          ),
        ];
      case LlmProviderKind.openaiCompat:
        return [
          _LabeledField(
            label: 'Base URL (OpenAI-compatible)',
            palette: palette,
            child: _settingsTextField(
              controller: _baseUrlCtrl,
              placeholder: 'http://localhost:1234/v1',
              palette: palette,
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'API key (optional)',
            palette: palette,
            child: _settingsTextField(
              controller: _apiKeyCtrl,
              placeholder: 'Leave empty if the server has no auth',
              palette: palette,
              obscure: true,
            ),
          ),
        ];
    }
  }

  void _showModelPicker(SettingsProvider settings) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) {
        final initialIdx =
            settings.availableModels.indexOf(settings.model ?? '');
        int selected = initialIdx >= 0 ? initialIdx : 0;
        return Container(
          height: 280,
          color: CupertinoColors.systemBackground.resolveFrom(ctx),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Cancel'),
                    ),
                    CupertinoButton(
                      onPressed: () {
                        settings.setModel(settings.availableModels[selected]);
                        Navigator.of(ctx).pop();
                      },
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CupertinoPicker(
                  itemExtent: 32,
                  scrollController:
                      FixedExtentScrollController(initialItem: selected),
                  onSelectedItemChanged: (i) => selected = i,
                  children: settings.availableModels
                      .map((m) => Center(child: Text(m)))
                      .toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final palette = AppColors.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 460, maxHeight: maxHeight),
        child: Container(
          margin: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: palette.scaffoldBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.divider),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DialogHeader(
                palette: palette,
                onClose: () => Navigator.of(context).pop(),
              ),
              Flexible(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    vertical: 16,
                    horizontal: 16,
                  ),
                  shrinkWrap: true,
                  children: [
                    _Section(
                      title: 'Appearance',
                      palette: palette,
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
                      palette: palette,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Receive in the background',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: palette.text,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Closing the window keeps Notilus in the '
                                    'tray so friends can still send you files.',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: palette.subtleText,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            CupertinoSwitch(
                              value: settings.backgroundReception,
                              onChanged: settings.setBackgroundReception,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Prefer local network',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: palette.text,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'When a contact is on the same network, send '
                                    'directly over the LAN (faster, no server). '
                                    'Falls back automatically otherwise.',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: palette.subtleText,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            CupertinoSwitch(
                              value: settings.preferLocalNetwork,
                              onChanged: settings.setPreferLocalNetwork,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _LabeledField(
                          label: 'Save received files to',
                          palette: palette,
                          child: CupertinoTextField(
                            controller: _destCtrl,
                            placeholder: '~/Downloads/Notilus (default)',
                            onSubmitted: settings.setTransferDestination,
                            onTapOutside: (_) =>
                                settings.setTransferDestination(_destCtrl.text),
                            decoration: BoxDecoration(
                              color: palette.cardBg,
                              border: Border.all(color: palette.divider),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 10,
                            ),
                            style: TextStyle(fontSize: 13, color: palette.text),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _Section(
                      title: 'AI Provider',
                      palette: palette,
                      children: [
                        CupertinoSlidingSegmentedControl<LlmProviderKind>(
                          groupValue: settings.provider,
                          children: {
                            for (final k in LlmProviderKind.values)
                              k: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 6,
                                ),
                                child: Text(
                                  k.label,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          },
                          onValueChanged: (v) {
                            if (v != null) _selectProvider(settings, v);
                          },
                        ),
                        const SizedBox(height: 12),
                        ..._providerFields(settings, palette),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            CupertinoButton.filled(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              onPressed: _testing
                                  ? null
                                  : () => _saveAndTest(settings),
                              child: _testing
                                  ? const CupertinoActivityIndicator(
                                      color: CupertinoColors.white,
                                      radius: 8,
                                    )
                                  : const Text(
                                      'Save & Test',
                                      style: TextStyle(fontSize: 13),
                                    ),
                            ),
                            const SizedBox(width: 12),
                            Icon(
                              settings.connected
                                  ? CupertinoIcons.check_mark_circled_solid
                                  : CupertinoIcons.xmark_circle_fill,
                              color: settings.connected
                                  ? palette.success
                                  : palette.danger,
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
                                  color: palette.subtleText,
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
                      palette: palette,
                      children: [
                        if (settings.availableModels.isEmpty)
                          Text(
                            settings.isConfigured(settings.provider)
                                ? 'No models available. Check the '
                                    '${settings.provider.label} connection above.'
                                : 'Configure ${settings.provider.label} above '
                                    'to load its models.',
                            style: TextStyle(
                              color: palette.subtleText,
                              fontSize: 12,
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: () => _showModelPicker(settings),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: palette.cardBg,
                                border: Border.all(color: palette.divider),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      settings.model ?? 'Pick a model',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: settings.model == null
                                            ? palette.subtleText
                                            : palette.text,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    CupertinoIcons.chevron_up_chevron_down,
                                    size: 14,
                                    color: palette.subtleText,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _Section(
                      title: 'Generation',
                      palette: palette,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Temperature',
                              style:
                                  TextStyle(fontSize: 13, color: palette.text),
                            ),
                            const Spacer(),
                            Text(
                              settings.temperature.toStringAsFixed(2),
                              style: TextStyle(
                                fontSize: 13,
                                color: palette.subtleText,
                              ),
                            ),
                          ],
                        ),
                        CupertinoSlider(
                          value: settings.temperature,
                          min: 0.0,
                          max: 1.5,
                          divisions: 30,
                          onChanged: (v) => settings.setTemperature(v),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.palette, required this.onClose});
  final AppPalette palette;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: Row(
        children: [
          Text(
            'Settings',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: palette.text,
            ),
          ),
          const Spacer(),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                CupertinoIcons.xmark,
                size: 18,
                color: palette.subtleText,
              ),
            ),
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
    return CupertinoSlidingSegmentedControl<AppThemeMode>(
      groupValue: current,
      children: const {
        AppThemeMode.system: _ThemeChip(
          icon: CupertinoIcons.gear_alt,
          label: 'System',
        ),
        AppThemeMode.light: _ThemeChip(
          icon: CupertinoIcons.sun_max,
          label: 'Light',
        ),
        AppThemeMode.dark: _ThemeChip(
          icon: CupertinoIcons.moon,
          label: 'Dark',
        ),
      },
      onValueChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _ThemeChip extends StatelessWidget {
  const _ThemeChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    required this.palette,
  });
  final String title;
  final List<Widget> children;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
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
              color: palette.subtleText,
            ),
          ),
        ),
        ...children,
      ],
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
            fontSize: 12,
            color: palette.subtleText,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}
