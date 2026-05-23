import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/file_entry.dart';
import '../services/file_service.dart';
import '../services/ollama_service.dart';

class ChatProvider extends ChangeNotifier {
  ChatProvider(this._fileService);

  final FileService _fileService;
  final List<ChatMessage> _messages = [];
  bool _busy = false;
  String? _error;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get busy => _busy;
  String? get error => _error;

  void clear() {
    _messages.clear();
    _error = null;
    notifyListeners();
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

    String prompt = userInput;
    if (attachedFile != null && !attachedFile.isDirectory) {
      final content = await _fileService.readTextCapped(attachedFile.path);
      prompt =
          'File: ${attachedFile.name}\n--- begin file ---\n$content\n--- end file ---\n\n$userInput';
      _messages.add(ChatMessage(
        role: ChatRole.user,
        content: '[+${attachedFile.name}] $userInput',
      ));
    } else {
      _messages.add(ChatMessage(role: ChatRole.user, content: userInput));
    }

    final assistant =
        ChatMessage(role: ChatRole.assistant, content: '', streaming: true);
    _messages.add(assistant);
    _busy = true;
    notifyListeners();

    final svc = OllamaService(host);
    try {
      await for (final chunk in svc.generate(
        model: model,
        prompt: prompt,
        temperature: temperature,
      )) {
        assistant.content += chunk;
        notifyListeners();
      }
    } catch (e) {
      _error = e.toString();
      assistant.content += '\n\n[error: $e]';
    } finally {
      assistant.streaming = false;
      _busy = false;
      notifyListeners();
    }
  }
}
