enum ChatRole { user, assistant, system }

class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    DateTime? createdAt,
    this.streaming = false,
  }) : createdAt = createdAt ?? DateTime.now();

  final ChatRole role;
  String content;
  final DateTime createdAt;
  bool streaming;
}
