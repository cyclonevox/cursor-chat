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
    this.titleFrozen = false,
    List<ChatMessage>? messages,
    DateTime? updatedAt,
  }) : messages = messages ?? [],
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String title;
  bool titleFrozen;
  String? agentId;
  String? pendingRunId;
  final List<ChatMessage> messages;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'titleFrozen': titleFrozen,
    'agentId': agentId,
    'pendingRunId': pendingRunId,
    'updatedAt': updatedAt.toIso8601String(),
    'messages': [for (final m in messages) m.toJson()],
  };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final title = json['title'] as String? ?? '新对话';
    return Conversation(
      id: json['id'] as String,
      title: title,
      titleFrozen: json['titleFrozen'] as bool? ?? title != '新对话',
      agentId: json['agentId'] as String?,
      pendingRunId: json['pendingRunId'] as String?,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      messages: [
        for (final m in json['messages'] as List? ?? const [])
          ChatMessage.fromJson(m as Map<String, dynamic>),
      ],
    );
  }
}

class CursorApiException implements Exception {
  CursorApiException(this.status, this.body);
  final int status;
  final String body;

  /// Create/stream finished before we subscribed — poll GET run instead.
  bool get isStreamGone {
    if (status == 410) return true;
    final b = body.toLowerCase();
    return b.contains('stream_unavailable') ||
        b.contains('no longer available');
  }

  @override
  String toString() => 'Cursor API $status: $body';
}

/// A cloud-agent run reached ERROR / CANCELLED / EXPIRED.
class RunFailedException implements Exception {
  RunFailedException(this.status, {this.message, this.code});

  final String status;
  final String? message;
  final String? code;

  String get userMessage {
    switch (status) {
      case 'CANCELLED':
        return '这次回复被取消了。';
      case 'EXPIRED':
        return '这次回复过期了。点重发再试。';
      default:
        final m = message?.trim() ?? '';
        if (m.isNotEmpty && !isFailedAssistantText(m)) {
          return '这次没答出来（$m）。点重发再试。';
        }
        return '这次没答出来。点重发再试，或新开对话。';
    }
  }

  @override
  String toString() =>
      'RunFailedException($status, code=$code, message=$message)';
}

bool isFailedRunStatus(String status) =>
    status == 'ERROR' || status == 'CANCELLED' || status == 'EXPIRED';

bool isFailedAssistantText(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (t.startsWith('出错了：') || t.startsWith('运行结束：')) return true;
  if (t == '（没有文字回复）') return true;
  return false;
}

String? runFailureMessage(Map<String, dynamic> data) {
  final err = data['error'];
  if (err is String && err.trim().isNotEmpty) return err.trim();
  if (err is Map) {
    final m = '${err['message'] ?? err['code'] ?? ''}'.trim();
    if (m.isNotEmpty) return m;
  }
  for (final key in ['message', 'text']) {
    final v = data[key];
    if (v is String && v.trim().isNotEmpty && !isFailedAssistantText(v)) {
      return v.trim();
    }
  }
  return null;
}
