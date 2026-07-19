import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/llm/llm_client.dart';
import '../theme.dart';

class ChatPanel extends StatefulWidget {
  const ChatPanel({super.key});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _attachSelection = true;
  FileEntry? _pickedFile;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final settings = context.read<SettingsProvider>();
    final browser = context.read<BrowserProvider>();
    final chat = context.read<ChatProvider>();

    final provider = chat.providerOverride ?? settings.provider;
    final model = chat.modelOverride ?? settings.modelFor(provider);
    if (model == null) {
      _showNoModelDialog();
      return;
    }

    // An explicitly picked file wins over the browser selection.
    final attached =
        _pickedFile ?? (_attachSelection ? browser.primarySelection : null);
    _controller.clear();
    if (_pickedFile != null) {
      setState(() => _pickedFile = null); // one-shot attachment
    }
    await chat.send(
      userInput: text,
      llm: settings.clientFor(provider),
      model: model,
      temperature: settings.temperature,
      attachedFile: attached,
    );
    _scrollToBottom();
  }

  Future<void> _pickFile() async {
    final xfile = await openFile();
    if (xfile == null) return;
    final entry = await FileEntry.from(File(xfile.path));
    if (entry == null || !mounted) return;
    setState(() => _pickedFile = entry);
  }

  void _showNoModelDialog() {
    showCupertinoDialog<void>(
      context: context,
      builder: (_) => CupertinoAlertDialog(
        title: const Text('No model selected'),
        content: const Text(
            'Configure an AI provider and pick a model in Settings first.'),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showLlmPicker() {
    final settings = context.read<SettingsProvider>();
    final chat = context.read<ChatProvider>();
    final defaultModel = settings.modelFor(settings.provider);
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Model for this chat'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(ctx).pop();
              chat.setLlmOverride(null, null);
            },
            child: Text(
              'App default (${settings.provider.label} · '
              '${defaultModel ?? 'no model'})',
              style: const TextStyle(fontSize: 14),
            ),
          ),
          for (final p in settings.configuredProviders)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(ctx).pop();
                _pickModelFor(p);
              },
              child: Text('${p.label}…', style: const TextStyle(fontSize: 14)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  Future<void> _pickModelFor(LlmProviderKind provider) async {
    final settings = context.read<SettingsProvider>();
    if (settings.modelsFor(provider).isEmpty) {
      await settings.refreshModelsFor(provider);
    }
    if (!mounted) return;
    final models = settings.modelsFor(provider);
    if (models.isEmpty) {
      showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text('No ${provider.label} models'),
          content: const Text(
              'Could not load the model list. Check the provider '
              'configuration in Settings.'),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final chat = context.read<ChatProvider>();
    final current = chat.providerOverride == provider
        ? chat.modelOverride
        : settings.modelFor(provider);
    final initialIdx = models.indexOf(current ?? '');
    int selected = initialIdx >= 0 ? initialIdx : 0;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
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
                      chat.setLlmOverride(provider, models[selected]);
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
                children:
                    models.map((m) => Center(child: Text(m))).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final browser = context.watch<BrowserProvider>();
    final settings = context.watch<SettingsProvider>();
    final palette = AppColors.of(context);
    final selection = browser.primarySelection;

    final provider = chat.providerOverride ?? settings.provider;
    final model = chat.modelOverride ?? settings.modelFor(provider);

    if (chat.messages.isNotEmpty) _scrollToBottom();

    return ColoredBox(
      color: palette.contentBg,
      child: Column(
        children: [
          Expanded(
            child: chat.messages.isEmpty
                ? const _ChatEmpty()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(10),
                    itemCount: chat.messages.length,
                    itemBuilder: (_, i) => _Bubble(message: chat.messages[i]),
                  ),
          ),
          _ChatComposer(
            controller: _controller,
            selection: selection,
            pickedFile: _pickedFile,
            attachSelection: _attachSelection,
            llmLabel: '${provider.label} · ${model ?? 'pick a model'}',
            onTapLlm: _showLlmPicker,
            onPickFile: _pickFile,
            onClearPickedFile: _pickedFile == null
                ? null
                : () => setState(() => _pickedFile = null),
            onToggleAttach: selection == null
                ? null
                : (v) => setState(() => _attachSelection = v),
            onSend: _send,
            onStop: chat.busy ? chat.cancel : null,
            onClear: chat.messages.isEmpty ? null : chat.clear,
            busy: chat.busy,
          ),
        ],
      ),
    );
  }
}

class _ChatEmpty extends StatelessWidget {
  const _ChatEmpty();

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.bubble_left_bubble_right,
              size: 36,
              color: palette.subtleText,
            ),
            const SizedBox(height: 12),
            Text(
              'Ask AI anything',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Attach a file with the paperclip, or select one and tick '
              '“Include selection” to send it as context.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: palette.subtleText,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatComposer extends StatelessWidget {
  const _ChatComposer({
    required this.controller,
    required this.selection,
    required this.pickedFile,
    required this.attachSelection,
    required this.llmLabel,
    required this.onTapLlm,
    required this.onPickFile,
    required this.onClearPickedFile,
    required this.onToggleAttach,
    required this.onSend,
    required this.onStop,
    required this.onClear,
    required this.busy,
  });

  final TextEditingController controller;
  final dynamic selection;
  final FileEntry? pickedFile;
  final bool attachSelection;
  final String llmLabel;
  final VoidCallback onTapLlm;
  final VoidCallback onPickFile;
  final VoidCallback? onClearPickedFile;
  final ValueChanged<bool>? onToggleAttach;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final VoidCallback? onClear;
  final bool busy;

  IconData _attachmentIcon(String? name) {
    if (name == null) return CupertinoIcons.doc;
    final lower = name.toLowerCase();
    final ext =
        lower.contains('.') ? lower.substring(lower.lastIndexOf('.')) : '';
    const img = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic'};
    const sheet = {'.xlsx', '.xls', '.ods', '.csv', '.tsv'};
    const slide = {'.pptx', '.ppt', '.odp'};
    if (img.contains(ext)) return CupertinoIcons.photo;
    if (ext == '.pdf') return CupertinoIcons.doc_richtext;
    if (sheet.contains(ext)) return CupertinoIcons.chart_bar_square;
    if (slide.contains(ext)) return CupertinoIcons.rectangle_on_rectangle;
    return CupertinoIcons.doc_text;
  }

  bool _isImage(String? name) {
    if (name == null) return false;
    final lower = name.toLowerCase();
    const img = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic'};
    final ext =
        lower.contains('.') ? lower.substring(lower.lastIndexOf('.')) : '';
    return img.contains(ext);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final hasSelection = selection != null;
    final attached = attachSelection && hasSelection;
    final attachedName = pickedFile?.name ??
        (attached ? selection.name as String : null);

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: GestureDetector(
                  onTap: onTapLlm,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: palette.cardBg,
                        border: Border.all(color: palette.divider),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.sparkles,
                            size: 12,
                            color: palette.accent,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              llmLabel,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: palette.text,
                              ),
                            ),
                          ),
                          const SizedBox(width: 3),
                          Icon(
                            CupertinoIcons.chevron_up_chevron_down,
                            size: 10,
                            color: palette.subtleText,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              CupertinoButton(
                padding: const EdgeInsets.all(4),
                onPressed: onPickFile,
                child: Icon(
                  CupertinoIcons.paperclip,
                  size: 15,
                  color:
                      pickedFile != null ? palette.accent : palette.subtleText,
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.all(4),
                onPressed: onClear,
                child: Icon(
                  CupertinoIcons.trash,
                  size: 15,
                  color: palette.subtleText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (pickedFile != null)
            Row(
              children: [
                Icon(
                  _attachmentIcon(pickedFile!.name),
                  size: 13,
                  color: palette.accent,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Attach: ${pickedFile!.name}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: palette.text),
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: onClearPickedFile,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Icon(
                      CupertinoIcons.xmark_circle_fill,
                      size: 14,
                      color: palette.subtleText,
                    ),
                  ),
                ),
              ],
            )
          else
            GestureDetector(
              onTap: onToggleAttach == null
                  ? null
                  : () => onToggleAttach!(!attached),
              child: MouseRegion(
                cursor: onToggleAttach == null
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                child: Row(
                  children: [
                    Icon(
                      attached
                          ? CupertinoIcons.checkmark_square_fill
                          : CupertinoIcons.square,
                      size: 16,
                      color: attached ? palette.accent : palette.subtleText,
                    ),
                    const SizedBox(width: 6),
                    if (hasSelection) ...[
                      Icon(
                        _attachmentIcon(selection.name as String),
                        size: 13,
                        color: palette.subtleText,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        hasSelection
                            ? 'Include: ${selection.name}'
                            : 'No selection',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.subtleText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_isImage(attachedName))
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 22),
              child: Text(
                'Vision-capable model required',
                style: TextStyle(fontSize: 10.5, color: palette.subtleText),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: CupertinoTextField(
                  controller: controller,
                  placeholder: 'Type a message…',
                  minLines: 1,
                  maxLines: 5,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: palette.cardBg,
                    border: Border.all(color: palette.divider),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  style: TextStyle(fontSize: 13, color: palette.text),
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 36,
                height: 32,
                child: CupertinoButton(
                  padding: EdgeInsets.zero,
                  color: busy ? CupertinoColors.systemRed : palette.accent,
                  borderRadius: BorderRadius.circular(8),
                  onPressed: busy ? onStop : onSend,
                  child: Icon(
                    busy ? CupertinoIcons.stop_fill : CupertinoIcons.arrow_up,
                    size: 16,
                    color: CupertinoColors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final isUser = message.role == ChatRole.user;
    final isSystem = message.role == ChatRole.system;

    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.info_circle,
              size: 13,
              color: palette.subtleText,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: SelectionArea(
                child: Text(
                  message.content,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: palette.subtleText,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final maxBubble = constraints.maxWidth.isFinite
            ? constraints.maxWidth * 0.82
            : 320.0;
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: BoxConstraints(maxWidth: maxBubble),
            decoration: BoxDecoration(
              color: isUser
                  ? palette.chatUserBubble
                  : palette.chatAssistantBubble,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectionArea(
              child: Text(
                message.content + (message.streaming ? ' ▌' : ''),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: palette.text,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
