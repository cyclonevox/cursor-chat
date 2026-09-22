import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../store.dart';
import '../widgets/answer_body.dart';
import 'chat_chrome.dart';

class MessageList extends StatefulWidget {
  const MessageList({super.key, required this.store});

  final ChatStore store;

  @override
  State<MessageList> createState() => MessageListState();
}

class MessageListState extends State<MessageList> {
  final _scroll = ScrollController();
  String? _boundConvId;
  bool _pinnedToLatest = true;
  String? _followedFor;

  ChatStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pinned = _scroll.position.pixels <= 48;
    if (pinned == _pinnedToLatest) return;
    setState(() => _pinnedToLatest = pinned);
  }

  void _bindConversation(String? id) {
    if (id == _boundConvId) return;
    _boundConvId = id;
    _pinnedToLatest = true;
    _followedFor = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToLatest();
    });
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(0);
    if (!_pinnedToLatest) setState(() => _pinnedToLatest = true);
  }

  @override
  Widget build(BuildContext context) {
    final conv = store.active;
    _bindConversation(conv?.id);
    final messages = conv?.messages ?? const <ChatMessage>[];
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 96, 32, 160),
          child: Text(
            '有问题就问，也可以拍照。\n拍题、日常问答、工作上都行。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      );
    }
    final modeLine = appBarModeLine(conv, store);
    final topPad =
        MediaQuery.paddingOf(context).top +
        chatBarHeight(context, twoLine: modeLine != null) +
        12;
    final last = messages.last;
    final token =
        '${conv!.id}:${last.id}:${last.text.length}:${last.streaming}';
    if (_pinnedToLatest && token != _followedFor) {
      _followedFor = token;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pinnedToLatest) _jumpToLatest();
      });
    }
    return Stack(
      children: [
        SelectionArea(
          child: ListView.builder(
            key: ValueKey(conv.id),
            controller: _scroll,
            reverse: true,
            padding: EdgeInsets.fromLTRB(16, 132, 16, topPad),
            itemCount: messages.length,
            itemBuilder: (context, i) {
              final index = messages.length - 1 - i;
              final message = messages[index];
              return _Bubble(
                key: ValueKey(message.id),
                message: message,
                store: store,
                showRetry:
                    index == messages.length - 1 &&
                    message.role == 'assistant' &&
                    store.canRetryLast,
              );
            },
          ),
        ),
        if (!_pinnedToLatest)
          Positioned(
            right: 16,
            bottom: 148,
            child: FilledButton.tonal(
              key: const Key('scroll-to-latest'),
              onPressed: _jumpToLatest,
              child: const Text('回到最新'),
            ),
          ),
      ],
    );
  }
}

Future<void> _copyReply(BuildContext context, String text) async {
  final t = text.trim();
  if (t.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: t));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.message,
    required this.store,
    this.showRetry = false,
  });

  final ChatMessage message;
  final ChatStore store;
  final bool showRetry;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(isUser ? 18 : 4),
      bottomRight: Radius.circular(isUser ? 4 : 18),
    );
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * (isUser ? 0.82 : 0.92),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isUser
                  ? scheme.primaryContainer.withValues(alpha: 0.88)
                  : scheme.surfaceContainerHigh.withValues(alpha: 0.72),
              borderRadius: radius,
              border: Border.all(
                color: scheme.outline.withValues(alpha: isUser ? 0.12 : 0.22),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.imagePaths.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final path in message.imagePaths)
                          if (File(path).existsSync())
                            _ChatImageThumb(
                              path: path,
                              gallery: [
                                for (final p in message.imagePaths)
                                  if (File(p).existsSync()) p,
                              ],
                            ),
                      ],
                    ),
                  if (message.imagePaths.isNotEmpty) const SizedBox(height: 8),
                  if (!isUser && message.thinking.trim().isNotEmpty)
                    _ThinkingTile(
                      thinking: message.thinking,
                      streaming: message.streaming && message.text.isEmpty,
                    ),
                  if (isUser) ...[
                    SelectableText(message.text),
                    if (message.queued)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '排队中',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: scheme.onPrimaryContainer.withValues(
                                      alpha: 0.72,
                                    ),
                                  ),
                            ),
                            IconButton(
                              key: Key('dequeue-${message.id}'),
                              tooltip: '取消排队',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => store.removeQueued(message.id),
                              icon: const Icon(Icons.close, size: 16),
                            ),
                          ],
                        ),
                      ),
                  ] else if (message.streaming && message.text.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else ...[
                    SizedBox(
                      width: double.infinity,
                      child: AnswerBody(
                        text: message.text.isEmpty ? '…' : message.text,
                      ),
                    ),
                    if (!message.streaming && message.text.trim().isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showRetry)
                              Tooltip(
                                message: '重发',
                                child: TextButton.icon(
                                  key: Key('retry-reply-${message.id}'),
                                  onPressed: store.sending
                                      ? null
                                      : () => unawaited(store.retryLast()),
                                  icon: const Icon(Icons.refresh, size: 18),
                                  label: const Text('重发'),
                                ),
                              ),
                            if (!isFailedAssistantText(message.text))
                              IconButton(
                                key: Key('copy-reply-${message.id}'),
                                tooltip: '复制',
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    _copyReply(context, message.text),
                                icon: const Icon(Icons.copy_outlined, size: 18),
                              ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatImageThumb extends StatelessWidget {
  const _ChatImageThumb({required this.path, required this.gallery});

  final String path;
  final List<String> gallery;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: Tooltip(
        message: '查看图片',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: Key('chat-image-$path'),
            onTap: () =>
                _openImageViewer(context, path: path, gallery: gallery),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _fileImage(path, width: 160, height: 140, cover: true),
            ),
          ),
        ),
      ),
    );
  }
}

/// Widget tests skip file codecs; they hang AutomatedTestWidgetsFlutterBinding.
@visibleForTesting
bool debugChatImagePlaceholder = false;

Widget _fileImage(
  String path, {
  required double width,
  required double height,
  bool cover = false,
}) {
  if (debugChatImagePlaceholder) {
    return SizedBox(
      width: width,
      height: height,
      child: const ColoredBox(
        color: Color(0xFF44555F),
        child: Icon(Icons.image, color: Colors.white70),
      ),
    );
  }
  return Image.file(
    File(path),
    width: width,
    height: height,
    fit: cover ? BoxFit.cover : BoxFit.contain,
    errorBuilder: (context, error, stack) => SizedBox(
      width: width,
      height: height,
      child: const ColoredBox(
        color: Color(0x33000000),
        child: Icon(Icons.broken_image_outlined),
      ),
    ),
  );
}

void _openImageViewer(
  BuildContext context, {
  required String path,
  required List<String> gallery,
}) {
  final paths = gallery.isEmpty ? [path] : gallery;
  var index = paths.indexOf(path);
  if (index < 0) index = 0;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _ImageViewerPage(paths: paths, initialIndex: index),
    ),
  );
}

class _ImageViewerPage extends StatefulWidget {
  const _ImageViewerPage({required this.paths, required this.initialIndex});

  final List<String> paths;
  final int initialIndex;

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  late final PageController _pages;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pages = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: widget.paths.length > 1
            ? Text('${_index + 1} / ${widget.paths.length}')
            : const Text('查看图片'),
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.paths.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Center(
              child: _fileImage(
                widget.paths[i],
                width: MediaQuery.sizeOf(context).width,
                height: MediaQuery.sizeOf(context).height,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ThinkingTile extends StatelessWidget {
  const _ThinkingTile({required this.thinking, required this.streaming});

  final String thinking;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = streaming ? '思考中…' : '思考过程';
    return Material(
      color: Colors.transparent,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          visualDensity: VisualDensity.compact,
          title: Text(
            thinking.trim().isEmpty ? label : '$label（点开查看）',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          children: [
            if (thinking.trim().isEmpty)
              Text(
                '还没有详细内容',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  thinking,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
