import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../settings/run_log_page.dart';
import '../settings/settings_page.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets/frosted.dart';
import 'chat_chrome.dart';
import 'composer.dart';
import 'conversation_drawer.dart';
import 'message_list.dart';

class ChatHome extends StatelessWidget {
  const ChatHome({super.key, required this.store});

  final ChatStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final conv = store.active;
        final scheme = Theme.of(context).colorScheme;
        final modeLine = appBarModeLine(conv, store);
        final barHeight = chatBarHeight(context, twoLine: modeLine != null);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlayFor(Theme.of(context).brightness),
          child: Scaffold(
            extendBody: true,
            extendBodyBehindAppBar: true,
            drawer: ConversationDrawer(store: store),
            appBar: AppBar(
              toolbarHeight: barHeight,
              flexibleSpace: const FrostedBar(),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    conv?.title ?? 'Cursor Chat',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (modeLine != null)
                    Text(
                      modeLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              actions: [
                if (conv?.kind == ConversationKind.isolated)
                  IconButton(
                    key: const Key('appbar-new'),
                    tooltip: '新开 Agent',
                    onPressed: store.newAgentChat,
                    icon: const Icon(Icons.cloud_outlined),
                  )
                else
                  IconButton(
                    key: const Key('appbar-new'),
                    tooltip: '新对话',
                    onPressed: store.newChat,
                    icon: const Icon(Icons.edit_square),
                  ),
                IconButton(
                  tooltip: '设置',
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsPage(store: store),
                      ),
                    );
                  },
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
            body: Stack(
              children: [
                MessageList(store: store),
                if (store.apiKey.trim().isEmpty || store.visibleError != null)
                  Align(
                    alignment: Alignment.topCenter,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: EdgeInsets.only(top: barHeight),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (store.apiKey.trim().isEmpty)
                              FrostedSurface(
                                sigma: 24,
                                tint: scheme.surface.withValues(alpha: 0.7),
                                border: Border(
                                  bottom: BorderSide(
                                    color: scheme.outline.withValues(
                                      alpha: 0.25,
                                    ),
                                  ),
                                ),
                                child: MaterialBanner(
                                  backgroundColor: Colors.transparent,
                                  surfaceTintColor: Colors.transparent,
                                  dividerColor: Colors.transparent,
                                  content: const Text(
                                    '还没有 API Key。打开设置，按里面的说明在网页上创建一个。',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) =>
                                                SettingsPage(store: store),
                                          ),
                                        );
                                      },
                                      child: const Text('去设置'),
                                    ),
                                  ],
                                ),
                              ),
                            if (store.visibleError != null)
                              FrostedSurface(
                                key: const Key('error-banner'),
                                sigma: 24,
                                tint: scheme.errorContainer.withValues(
                                  alpha: 0.72,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    10,
                                    8,
                                    4,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        store.visibleError!,
                                        style: TextStyle(
                                          color: scheme.onErrorContainer,
                                        ),
                                      ),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          if (store.canRetryLast)
                                            TextButton(
                                              key: const Key(
                                                'retry-error-banner',
                                              ),
                                              onPressed: () =>
                                                  unawaited(store.retryLast()),
                                              child: const Text('重发'),
                                            ),
                                          TextButton(
                                            key: const Key('open-run-log'),
                                            onPressed: () {
                                              Navigator.of(context).push(
                                                MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      RunLogPage(store: store),
                                                ),
                                              );
                                            },
                                            child: const Text('记录'),
                                          ),
                                          IconButton(
                                            onPressed: store.clearError,
                                            icon: const Icon(Icons.close),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Composer(store: store),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
