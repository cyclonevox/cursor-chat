import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

const uuid = Uuid();

class PromptImage {
  const PromptImage({required this.data, required this.mimeType, this.path});

  final String data;
  final String mimeType;
  final String? path;

  Map<String, String> toApiJson() => {'data': data, 'mimeType': mimeType};

  static Future<PromptImage> fromFile(File file) async {
    final bytes = await file.readAsBytes();
    if (bytes.length > 12 * 1024 * 1024) {
      throw CursorApiException(0, '图片太大，请换一张或压缩后再发');
    }
    final ext = file.path.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
    return PromptImage(
      data: base64Encode(bytes),
      mimeType: mime,
      path: file.path,
    );
  }
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.imagePaths = const [],
    this.streaming = false,
    this.thinking = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String role; // user | assistant | system
  String text;
  final List<String> imagePaths;
  bool streaming;
  String thinking;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'text': text,
    'imagePaths': imagePaths,
    'thinking': thinking,
    'streaming': streaming,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    role: json['role'] as String,
    text: json['text'] as String? ?? '',
    thinking: json['thinking'] as String? ?? '',
    streaming: json['streaming'] == true,
    imagePaths: [
      for (final p in json['imagePaths'] as List? ?? const []) p as String,
    ],
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}

class Conversation {
  Conversation({
    required this.id,
    required this.title,
    this.agentId,
    this.pendingRunId,
    List<ChatMessage>? messages,
    DateTime? updatedAt,
  }) : messages = messages ?? [],
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String title;
  String? agentId;
  String? pendingRunId;
  final List<ChatMessage> messages;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'agentId': agentId,
    'pendingRunId': pendingRunId,
    'updatedAt': updatedAt.toIso8601String(),
    'messages': [for (final m in messages) m.toJson()],
  };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    title: json['title'] as String? ?? '新对话',
    agentId: json['agentId'] as String?,
    pendingRunId: json['pendingRunId'] as String?,
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    messages: [
      for (final m in json['messages'] as List? ?? const [])
        ChatMessage.fromJson(m as Map<String, dynamic>),
    ],
  );
}

class CursorApiException implements Exception {
  CursorApiException(this.status, this.body);
  final int status;
  final String body;

  @override
  String toString() => 'Cursor API $status: $body';
}
