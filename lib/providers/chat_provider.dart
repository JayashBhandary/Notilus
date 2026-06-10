import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../models/file_entry.dart';
import '../services/attachment_service.dart';
import '../services/ollama_service.dart';

class ChatProvider extends ChangeNotifier {
  ChatProvider({AttachmentService? attachments})
      : _attachments = attachments ?? AttachmentService();

  final AttachmentService _attachments;
  final List<ChatMessage> _messages = [];
  bool _busy = false;
  String? _error;
  http.Client? _activeClient;
  bool _cancelled = false;

  // Images attached to each user message (by index in _messages).
  final Map<int, List<String>> _userImages = {};

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get busy => _busy;
  String? get error => _error;

  void clear() {
    if (_busy) cancel();
    _messages.clear();
    _userImages.clear();
    _error = null;
    notifyListeners();
  }

  void cancel() {
    if (!_busy) return;
    _cancelled = true;
    _activeClient?.close();
    _activeClient = null;
  }

  String _roleString(ChatRole r) {
    switch (r) {
      case ChatRole.user:
        return 'user';
      case ChatRole.assistant:
        return 'assistant';
      case ChatRole.system:
        return 'system';
    }
  }

  Future<void> send({
    required String userInput,
    required String host,
    required String model,
    required double temperature,
    FileEntry? attachedFile,
  }) async {
    if (_busy) return;
    _error = null;

    ChatAttachment? att;
    if (attachedFile != null && !attachedFile.isDirectory) {
      att = await _attachments.prepare(attachedFile);
    }

    // Build the user-visible label, the body sent to the model, and the
    // per-message image list.
    String userDisplay;
    String userBody = userInput;
    List<String>? images;
    String? noticeForUi;

    if (att == null) {
      userDisplay = userInput;
    } else {
      switch (att.kind) {
        case AttachmentKind.text:
          userBody =
              'File: ${att.name}\n--- begin file ---\n${att.text}\n--- end file ---\n\n$userInput';
          userDisplay = '[+${att.name}] $userInput';
          break;
        case AttachmentKind.image:
          // Vision models read images directly; the prompt only mentions the
          // filename so the model can refer to it.
          userBody = 'Image: ${att.name}\n\n$userInput';
          userDisplay = '[+${att.name}] $userInput';
          images = [att.imageBase64!];
          noticeForUi = att.notice;
          break;
        case AttachmentKind.unsupported:
          userBody = 'File: ${att.name} (could not be extracted)\n\n$userInput';
          userDisplay = '[+${att.name}] $userInput';
          noticeForUi = att.notice;
          break;
      }
    }

    final userMsg = ChatMessage(role: ChatRole.user, content: userDisplay);
    _messages.add(userMsg);
    final userIndex = _messages.length - 1;
    if (images != null) {
      _userImages[userIndex] = images;
    }

    if (noticeForUi != null && att?.kind == AttachmentKind.unsupported) {
      // Surface unsupported-attachment notice as a system bubble so the user
      // sees why nothing useful happened.
      _messages.add(
        ChatMessage(role: ChatRole.system, content: noticeForUi),
      );
    }

    final assistant =
        ChatMessage(role: ChatRole.assistant, content: '', streaming: true);
    _messages.add(assistant);
    _busy = true;
    notifyListeners();

    // Build conversation history (everything except the assistant placeholder
    // we just added). For the current user turn, swap in the augmented body
    // and attach images.
    final turns = <OllamaChatTurn>[];
    for (var i = 0; i < _messages.length - 1; i++) {
      final m = _messages[i];
      if (m.role == ChatRole.system &&
          (att?.kind == AttachmentKind.unsupported) &&
          identical(m.content, noticeForUi)) {
        continue; // skip the UI-only notice
      }
      final isCurrentUser = i == userIndex;
      turns.add(OllamaChatTurn(
        role: _roleString(m.role),
        content: isCurrentUser ? userBody : m.content,
        images: isCurrentUser ? images : _userImages[i],
      ));
    }

    final svc = OllamaService(host);
    final client = http.Client();
    _activeClient = client;
    _cancelled = false;
    try {
      await for (final chunk in svc.chat(
        model: model,
        messages: turns,
        temperature: temperature,
        client: client,
      )) {
        assistant.content += chunk;
        notifyListeners();
      }
    } catch (e) {
      if (_cancelled) {
        if (assistant.content.isNotEmpty) {
          assistant.content += '\n\n[stopped]';
        } else {
          assistant.content = '[stopped]';
        }
      } else {
        _error = e.toString();
        assistant.content += assistant.content.isEmpty
            ? '[error: $e]'
            : '\n\n[error: $e]';
      }
    } finally {
      assistant.streaming = false;
      _busy = false;
      _cancelled = false;
      if (identical(_activeClient, client)) _activeClient = null;
      try {
        client.close();
      } catch (_) {}
      notifyListeners();
    }
  }
}
