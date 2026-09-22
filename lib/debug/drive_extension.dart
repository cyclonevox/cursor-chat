import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import '../store.dart';

void registerChatDrive(ChatStore store) {
  developer.registerExtension('ext.cursor_chat.drive', (method, params) async {
    try {
      final action = params['action'] ?? 'status';
      if (action == 'status') {
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'modelId': store.modelId,
            'stamp': store.modelStamp,
            'quickAgentId': store.quickAgentId,
            'quickStamp': store.quickAgentModelStamp,
            'next': store.nextQuickAgentId,
            'nextReady': store.nextQuickAgentReady,
            'nextStamp': store.nextQuickAgentModelStamp,
            'models': [for (final m in store.models) m.id],
            'active': store.activeId,
            'error': store.error,
            'sending': store.sending,
          }),
        );
      }
      if (action == 'send') {
        store.newChat();
        final id = store.activeId;
        unawaited(store.send(text: params['text'] ?? ''));
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'active': id, 'modelId': store.modelId}),
        );
      }
      if (action == 'follow') {
        final id = store.activeId;
        unawaited(store.send(text: params['text'] ?? ''));
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'active': id, 'modelId': store.modelId}),
        );
      }
      if (action == 'switch') {
        final model = params['model'] ?? '';
        if (model.isEmpty) {
          return developer.ServiceExtensionResponse.error(1, 'no model');
        }
        store.selectModel(model);
        store.newChat();
        final id = store.activeId;
        unawaited(store.send(text: params['text'] ?? ''));
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'active': id,
            'modelId': store.modelId,
            'quick': store.quickAgentId,
            'next': store.nextQuickAgentId,
            'nextReady': store.nextQuickAgentReady,
          }),
        );
      }
      if (action == 'export') {
        final path = await store.exportRunLog();
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'path': path}),
        );
      }
      return developer.ServiceExtensionResponse.error(1, 'unknown');
    } catch (e) {
      return developer.ServiceExtensionResponse.error(1, '$e');
    }
  });
}
