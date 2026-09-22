import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../store.dart';
import '../widgets/frosted.dart';

Future<void> _confirmDeleteChat(
  BuildContext context,
  ChatStore store,
  Conversation conv,
) async {
  if (conv.kind == ConversationKind.isolated &&
      conv.agentId != null &&
      conv.agentId!.isNotEmpty) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话'),
        content: const Text('也会删除云端的这只 Agent，不能恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
  }
  await store.deleteChat(conv.id);
}

class ConversationDrawer extends StatefulWidget {
  const ConversationDrawer({super.key, required this.store});

  final ChatStore store;

  @override
  State<ConversationDrawer> createState() => _ConversationDrawerState();
}

class _ConversationDrawerState extends State<ConversationDrawer> {
  bool _topicsExpanded = true;
  bool _agentsExpanded = true;

  ChatStore get store => widget.store;

  void _close() => Navigator.pop(context);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Drawer(
      child: FrostedSurface(
        sigma: 36,
        tint: scheme.surface.withValues(
          alpha: Theme.of(context).brightness == Brightness.dark ? 0.58 : 0.72,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                  child: Text(
                    '对话',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Divider(
                  height: 1,
                  color: scheme.outline.withValues(alpha: 0.3),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      _DrawerSection(
                        title: '快速对话',
                        expanded: _topicsExpanded,
                        selected: store.active?.kind == ConversationKind.topic,
                        addTooltip: '新对话',
                        addKey: const Key('drawer-add-topic'),
                        toggleKey: const Key('drawer-toggle-topics'),
                        onToggle: () =>
                            setState(() => _topicsExpanded = !_topicsExpanded),
                        onAdd: () {
                          setState(() => _topicsExpanded = true);
                          store.newChat();
                          _close();
                        },
                      ),
                      if (_topicsExpanded) ...[
                        for (final c in store.topicChats)
                          _DrawerChatTile(
                            store: store,
                            conversation: c,
                            indented: true,
                          ),
                        if (store.topicChats.isEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(48, 4, 16, 12),
                            child: Text(
                              '点 + 开一个话题。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                      _DrawerSection(
                        title: '独立 Agent',
                        expanded: _agentsExpanded,
                        selected:
                            store.active?.kind == ConversationKind.isolated,
                        addTooltip: '新开 Agent',
                        addKey: const Key('drawer-add-agent'),
                        toggleKey: const Key('drawer-toggle-agents'),
                        onToggle: () =>
                            setState(() => _agentsExpanded = !_agentsExpanded),
                        onAdd: () {
                          setState(() => _agentsExpanded = true);
                          store.newAgentChat();
                          _close();
                        },
                      ),
                      if (_agentsExpanded) ...[
                        for (final c in store.isolatedChats)
                          _DrawerChatTile(store: store, conversation: c),
                        if (store.isolatedChats.isEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
                            child: Text(
                              '点 + 单独建一只 Agent。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerSection extends StatelessWidget {
  const _DrawerSection({
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.onAdd,
    required this.addTooltip,
    this.selected = false,
    this.addKey,
    this.toggleKey,
  });

  final String title;
  final bool expanded;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onAdd;
  final String addTooltip;
  final Key? addKey;
  final Key? toggleKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant);
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.14)
          : Colors.transparent,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            IconButton(
              key: toggleKey,
              tooltip: expanded ? '折叠$title' : '展开$title',
              visualDensity: VisualDensity.compact,
              onPressed: onToggle,
              icon: Icon(expanded ? Icons.expand_more : Icons.chevron_right),
            ),
            Expanded(
              child: InkWell(
                onTap: onToggle,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(title, style: labelStyle),
                ),
              ),
            ),
            IconButton(
              key: addKey,
              tooltip: addTooltip,
              visualDensity: VisualDensity.compact,
              onPressed: onAdd,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerChatTile extends StatelessWidget {
  const _DrawerChatTile({
    required this.store,
    required this.conversation,
    this.indented = false,
  });

  final ChatStore store;
  final Conversation conversation;
  final bool indented;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = conversation;
    final subtitle = store.isSending(c.id)
        ? '回复中…'
        : store.isQueued(c.id)
        ? '排队中'
        : null;
    return ListTile(
      contentPadding: EdgeInsets.only(left: indented ? 48 : 16, right: 8),
      selected: c.id == store.active?.id,
      selectedTileColor: scheme.primary.withValues(alpha: 0.14),
      title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () {
        store.selectChat(c.id);
        Navigator.pop(context);
      },
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDeleteChat(context, store, c),
      ),
    );
  }
}
