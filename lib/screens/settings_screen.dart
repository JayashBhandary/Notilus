import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _hostCtrl;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _hostCtrl =
        TextEditingController(text: context.read<SettingsProvider>().host);
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest(SettingsProvider settings) async {
    setState(() => _testing = true);
    await settings.setHost(_hostCtrl.text.trim());
    if (mounted) setState(() => _testing = false);
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

    return CupertinoPageScaffold(
      backgroundColor: palette.scaffoldBg,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
        middle: const Text('Settings'),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
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
              title: 'Ollama',
              palette: palette,
              children: [
                _LabeledField(
                  label: 'Host URL',
                  palette: palette,
                  child: CupertinoTextField(
                    controller: _hostCtrl,
                    placeholder: 'http://localhost:11434',
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
                const SizedBox(height: 12),
                Row(
                  children: [
                    CupertinoButton.filled(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      onPressed:
                          _testing ? null : () => _saveAndTest(settings),
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
                            : 'Not connected',
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
                    'No models available. Make sure Ollama is running and reachable.',
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
                      style: TextStyle(fontSize: 13, color: palette.text),
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
          padding: const EdgeInsets.only(left: 4, bottom: 6),
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
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: palette.cardBg,
            border: Border.all(color: palette.divider),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
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
