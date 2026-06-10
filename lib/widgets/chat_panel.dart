import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../providers/browser_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
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

    if (settings.model == null) {
      _showNoModelDialog();
      return;
    }

    final attached = _attachSelection ? browser.primarySelection : null;
    _controller.clear();
    await chat.send(
      userInput: text,
      host: settings.host,
      model: settings.model!,
      temperature: settings.temperature,
      attachedFile: attached,
    );
    _scrollToBottom();
  }

  void _showNoModelDialog() {
    showCupertinoDialog<void>(
      context: context,
      builder: (_) => CupertinoAlertDialog(
        title: const Text('No model selected'),
        content: const Text('Open Settings and pick a model first.'),
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

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);
    final selection = browser.primarySelection;

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
            attachSelection: _attachSelection,
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
              'Ask Ollama anything',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Select a file and tick “Include selection” to send it as context.',
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
    required this.attachSelection,
    required this.onToggleAttach,
    required this.onSend,
    required this.onStop,
    required this.onClear,
    required this.busy,
  });

  final TextEditingController controller;
  final dynamic selection;
  final bool attachSelection;
  final ValueChanged<bool>? onToggleAttach;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final VoidCallback? onClear;
  final bool busy;

  IconData _attachmentIcon(dynamic sel) {
    if (sel == null) return CupertinoIcons.doc;
    final name = (sel.name as String).toLowerCase();
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')) : '';
    const img = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic'};
    const sheet = {'.xlsx', '.xls', '.ods', '.csv', '.tsv'};
    const slide = {'.pptx', '.ppt', '.odp'};
    if (img.contains(ext)) return CupertinoIcons.photo;
    if (ext == '.pdf') return CupertinoIcons.doc_richtext;
    if (sheet.contains(ext)) return CupertinoIcons.chart_bar_square;
    if (slide.contains(ext)) return CupertinoIcons.rectangle_on_rectangle;
    return CupertinoIcons.doc_text;
  }

  bool _isImage(dynamic sel) {
    if (sel == null) return false;
    final name = (sel.name as String).toLowerCase();
    const img = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic'};
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')) : '';
    return img.contains(ext);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final hasSelection = selection != null;
    final attached = attachSelection && hasSelection;

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
                          color: attached
                              ? palette.accent
                              : palette.subtleText,
                        ),
                        const SizedBox(width: 6),
                        if (hasSelection) ...[
                          Icon(
                            _attachmentIcon(selection),
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
              ),
              const SizedBox(width: 8),
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
          if (attached && _isImage(selection))
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 22),
              child: Text(
                'Vision model required (e.g. llava, llama3.2-vision)',
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
