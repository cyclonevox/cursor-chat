import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'models/models.dart';
import 'settings/settings_page.dart';
import 'store.dart';
import 'theme.dart';
import 'voice/create_engine.dart';
import 'voice/pcm_recorder.dart';
import 'voice/stt_engine.dart';
import 'widgets/answer_body.dart';
import 'widgets/frosted.dart';
import 'widgets/voice_listening_bar.dart';

export 'settings/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final store = ChatStore();
  await store.load();
  runApp(ChatApp(store: store));
}

class ChatApp extends StatefulWidget {
  const ChatApp({super.key, required this.store});

  final ChatStore store;

  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.store.resumeInFlight());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cursor Chat',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      home: ChatHome(store: widget.store),
    );
  }
}

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
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlayFor(Theme.of(context).brightness),
          child: Scaffold(
            extendBody: true,
            extendBodyBehindAppBar: true,
            drawer: ConversationDrawer(store: store),
            appBar: AppBar(
              flexibleSpace: const FrostedBar(),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(conv?.title ?? 'Cursor Chat'),
                  if (store.models.isNotEmpty)
                    Text(
                      store.modelSummary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              actions: [
                IconButton(
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
                _MessageList(store: store),
                if (store.apiKey.trim().isEmpty || store.visibleError != null)
                  Align(
                    alignment: Alignment.topCenter,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.only(top: kToolbarHeight),
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
                                sigma: 24,
                                tint: scheme.errorContainer.withValues(
                                  alpha: 0.72,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    4,
                                    8,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          store.visibleError!,
                                          style: TextStyle(
                                            color: scheme.onErrorContainer,
                                          ),
                                        ),
                                      ),
                                      if (store.canRetryLast)
                                        TextButton(
                                          key: const Key('retry-error-banner'),
                                          onPressed: () =>
                                              unawaited(store.retryLast()),
                                          child: const Text('重发'),
                                        ),
                                      IconButton(
                                        onPressed: store.clearError,
                                        icon: const Icon(Icons.close),
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

class ConversationDrawer extends StatelessWidget {
  const ConversationDrawer({super.key, required this.store});

  final ChatStore store;

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
                ListTile(
                  leading: const Icon(Icons.edit_square),
                  title: const Text('新对话'),
                  onTap: () {
                    store.newChat();
                    Navigator.pop(context);
                  },
                ),
                Divider(
                  height: 1,
                  color: scheme.outline.withValues(alpha: 0.3),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: store.conversations.length,
                    itemBuilder: (context, i) {
                      final c = store.conversations[i];
                      final selected = c.id == store.active?.id;
                      return ListTile(
                        selected: selected,
                        selectedTileColor: scheme.primary.withValues(
                          alpha: 0.14,
                        ),
                        title: Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: store.isSending(c.id)
                            ? const Text('回复中…')
                            : null,
                        onTap: () {
                          store.selectChat(c.id);
                          Navigator.pop(context);
                        },
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => store.deleteChat(c.id),
                        ),
                      );
                    },
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

class _MessageList extends StatefulWidget {
  const _MessageList({required this.store});

  final ChatStore store;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final _scroll = ScrollController();
  final _latestUserKey = GlobalKey();
  String? _revealedFor;

  ChatStore get store => widget.store;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conv = store.active;
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
    final topPad = MediaQuery.paddingOf(context).top + kToolbarHeight + 12;
    final userIndex = messages.lastIndexWhere((m) => m.role == 'user');
    final anchorIndex = userIndex >= 0 ? userIndex : messages.length - 1;
    final token = '${conv!.id}:${messages[anchorIndex].id}';
    if (token != _revealedFor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealLatestUser(token);
      });
    }
    // reverse:true pins the newest bubble to the visual bottom. Vertical
    // padding is swapped along the scroll axis, so composer space goes in
    // [top] and the app-bar inset goes in [bottom].
    return SelectionArea(
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
            key: index == anchorIndex ? _latestUserKey : ValueKey(message.id),
            message: message,
            store: store,
            showRetry:
                index == messages.length - 1 &&
                message.role == 'assistant' &&
                store.canRetryLast,
          );
        },
      ),
    );
  }

  void _revealLatestUser(String token, [int attempt = 0]) {
    if (!mounted || _revealedFor == token) return;
    final ctx = _latestUserKey.currentContext;
    if (ctx == null) {
      if (attempt >= 12 || !_scroll.hasClients) return;
      final pos = _scroll.position;
      final next = (pos.pixels + pos.viewportDimension * 0.9).clamp(
        0.0,
        pos.maxScrollExtent,
      );
      if (next > pos.pixels + 1) _scroll.jumpTo(next);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _revealLatestUser(token, attempt + 1);
      });
      return;
    }
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final minY = MediaQuery.paddingOf(ctx).top + kToolbarHeight;
    if (top < minY - 8) {
      Scrollable.ensureVisible(ctx, alignment: 0.0, duration: Duration.zero);
    }
    _revealedFor = token;
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
                  if (isUser)
                    SelectableText(message.text)
                  else if (message.streaming && message.text.isEmpty)
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

class Composer extends StatefulWidget {
  const Composer({super.key, required this.store});

  final ChatStore store;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _picker = ImagePicker();
  final List<PromptImage> _images = [];
  bool _picking = false;
  bool _listening = false;
  bool _transcribing = false;
  String _voiceAnchor = '';
  SttEngine? _stt;
  Timer? _voiceClock;
  Duration _voiceElapsed = Duration.zero;
  final List<double> _voiceLevels = List<double>.filled(56, 0);
  bool _voiceLevelDirty = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      unawaited(_recoverLostCrop());
    }
  }

  Future<void> _recoverLostCrop() async {
    try {
      final lost = await ImageCropper().recoverImage();
      if (lost == null || !mounted) return;
      final img = await _persistFile(File(lost.path));
      setState(() => _images.add(img));
    } catch (_) {}
  }

  @override
  void dispose() {
    _voiceClock?.cancel();
    unawaited(_stt?.cancel());
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _resetVoiceVisual() {
    _voiceClock?.cancel();
    _voiceClock = null;
    _voiceElapsed = Duration.zero;
    for (var i = 0; i < _voiceLevels.length; i++) {
      _voiceLevels[i] = 0;
    }
  }

  void _beginVoiceVisual() {
    _voiceElapsed = Duration.zero;
    for (var i = 0; i < _voiceLevels.length; i++) {
      _voiceLevels[i] = 0;
    }
    _voiceClock?.cancel();
    _voiceClock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_listening) return;
      setState(() => _voiceElapsed += const Duration(seconds: 1));
    });
  }

  void _onVoiceLevel(double level) {
    if (!mounted || !_listening) return;
    _voiceLevels.removeAt(0);
    _voiceLevels.add(boostVoiceMeter(level));
    if (_voiceLevelDirty) return;
    _voiceLevelDirty = true;
    scheduleMicrotask(() {
      _voiceLevelDirty = false;
      if (mounted && _listening) setState(() {});
    });
  }

  void _hideKeyboard() {
    _focus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod('TextInput.hide'));
  }

  Future<void> _startVoice() async {
    if (_listening || _transcribing || widget.store.sending) return;
    if (!widget.store.voiceMicReady) return;
    _hideKeyboard();
    _voiceAnchor = _controller.text;
    final engine = createSttEngine(widget.store);
    _stt = engine;
    setState(() => _listening = true);
    _beginVoiceVisual();
    try {
      await engine.start(
        onPartial: (partial) {
          if (!mounted || !_listening) return;
          _controller.text = joinTranscript(_voiceAnchor, partial);
          _controller.selection = TextSelection.collapsed(
            offset: _controller.text.length,
          );
        },
        onLevel: _onVoiceLevel,
      );
    } catch (e) {
      try {
        await engine.cancel();
      } catch (_) {}
      if (!mounted) return;
      _resetVoiceVisual();
      setState(() => _listening = false);
      _stt = null;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _confirmVoice() async {
    final engine = _stt;
    if (engine == null || _transcribing) return;
    setState(() {
      _listening = false;
      _transcribing = true;
      _voiceClock?.cancel();
      _voiceClock = null;
    });
    try {
      final text = await engine.finish();
      if (!mounted) return;
      _controller.text = joinTranscript(_voiceAnchor, text);
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    } catch (e) {
      if (!mounted) return;
      _controller.text = _voiceAnchor;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      _stt = null;
      _resetVoiceVisual();
      if (mounted) setState(() => _transcribing = false);
    }
  }

  Future<void> _cancelVoice() async {
    final engine = _stt;
    _stt = null;
    try {
      await engine?.cancel();
    } catch (_) {}
    if (!mounted) return;
    _controller.text = _voiceAnchor;
    _resetVoiceVisual();
    setState(() {
      _listening = false;
      _transcribing = false;
    });
  }

  Future<void> _addFromPicker(ImageSource source) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 2560,
        imageQuality: 92,
      );
      if (file == null) return;
      final croppedPath = await _cropIfNeeded(file.path);
      if (croppedPath == null) return;
      final img = await _persistFile(File(croppedPath));
      if (!mounted) return;
      setState(() => _images.add(img));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _addFromFiles() async {
    final files = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'images',
          extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
        ),
      ],
    );
    for (final f in files) {
      final img = await _persistFile(File(f.path));
      if (!mounted) return;
      setState(() => _images.add(img));
    }
  }

  Future<String?> _cropIfNeeded(String path) async {
    if (!Platform.isAndroid) return path;
    try {
      final cropped = await ImageCropper().cropImage(
        sourcePath: path,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: '裁切',
            toolbarColor: const Color(0xFF121212),
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: const Color(0xFF5EEAD4),
            lockAspectRatio: false,
            initAspectRatio: CropAspectRatioPreset.original,
            statusBarLight: false,
            aspectRatioPresets: const [
              CropAspectRatioPreset.original,
              CropAspectRatioPreset.ratio4x3,
              CropAspectRatioPreset.ratio16x9,
              CropAspectRatioPreset.square,
            ],
          ),
        ],
      );
      await ImageCropper().recoverImage();
      return cropped?.path;
    } catch (_) {
      return path;
    }
  }

  Future<PromptImage> _persistFile(File file) async {
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/images/${uuid.v4()}.jpg');
    await dest.parent.create(recursive: true);
    await file.copy(dest.path);
    return PromptImage.fromFile(dest);
  }

  Future<void> _recropAt(int index) async {
    final current = _images[index];
    if (current.path == null || !Platform.isAndroid) return;
    final croppedPath = await _cropIfNeeded(current.path!);
    if (croppedPath == null || !mounted) return;
    final img = await _persistFile(File(croppedPath));
    if (!mounted) return;
    setState(() => _images[index] = img);
  }

  Future<void> _send() async {
    final text = _controller.text;
    final images = List<PromptImage>.from(_images);
    if (text.trim().isEmpty && images.isEmpty) return;
    _controller.clear();
    setState(() => _images.clear());
    await widget.store.send(text: text, images: images);
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.store.sending;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: FrostedSurface(
          sigma: 34,
          tint: scheme.surface.withValues(alpha: dark ? 0.48 : 0.66),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: scheme.outline.withValues(alpha: 0.32)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_images.isNotEmpty)
                  SizedBox(
                    height: 72,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      scrollDirection: Axis.horizontal,
                      itemCount: _images.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final img = _images[i];
                        return Stack(
                          children: [
                            if (img.path != null)
                              GestureDetector(
                                onTap: busy ? null : () => _recropAt(i),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.file(
                                    File(img.path!),
                                    width: 72,
                                    height: 72,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            Positioned(
                              right: 0,
                              top: 0,
                              child: IconButton.filledTonal(
                                style: IconButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () =>
                                    setState(() => _images.removeAt(i)),
                                icon: const Icon(Icons.close, size: 16),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: '相册',
                      onPressed: busy || _listening || _transcribing
                          ? null
                          : () {
                              if (Platform.isLinux) {
                                _addFromFiles();
                              } else {
                                _addFromPicker(ImageSource.gallery);
                              }
                            },
                      icon: const Icon(Icons.add),
                    ),
                    if (!Platform.isLinux && !_listening && !_transcribing)
                      IconButton(
                        tooltip: '拍照',
                        onPressed: busy
                            ? null
                            : () => _addFromPicker(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined),
                      ),
                    Expanded(
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          Opacity(
                            opacity: _listening || _transcribing ? 0 : 1,
                            child: IgnorePointer(
                              ignoring: _listening || _transcribing,
                              child: TextField(
                                key: const Key('composer-input'),
                                controller: _controller,
                                focusNode: _focus,
                                minLines: 1,
                                maxLines: _listening || _transcribing ? 1 : 6,
                                textInputAction: TextInputAction.newline,
                                enabled: !busy && !_listening && !_transcribing,
                                decoration: const InputDecoration(
                                  hintText: '问点什么…',
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 10,
                                  ),
                                ),
                                onSubmitted: (_) {
                                  if (!busy) _send();
                                },
                              ),
                            ),
                          ),
                          if (_listening || _transcribing)
                            VoiceListeningBar(
                              key: const Key('composer-voice-meter'),
                              levels: List<double>.from(_voiceLevels),
                              elapsed: _voiceElapsed,
                              transcribing: _transcribing,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (widget.store.voiceMicReady &&
                        (_listening || _transcribing)) ...[
                      IconButton(
                        key: const Key('composer-voice-cancel'),
                        tooltip: '取消',
                        onPressed: busy || _transcribing ? null : _cancelVoice,
                        icon: const Icon(Icons.close),
                      ),
                      IconButton.filledTonal(
                        key: const Key('composer-voice-confirm'),
                        tooltip: '完成',
                        onPressed: busy || _transcribing ? null : _confirmVoice,
                        icon: _transcribing
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.primary,
                                ),
                              )
                            : const Icon(Icons.check),
                      ),
                    ] else if (widget.store.voiceMicReady)
                      IconButton(
                        key: const Key('composer-mic'),
                        tooltip: '语音输入',
                        onPressed: busy ? null : _startVoice,
                        icon: const Icon(Icons.mic_none_outlined),
                      ),
                    if (!_listening && !_transcribing)
                      IconButton.filled(
                        key: const Key('composer-send'),
                        tooltip: '发送',
                        onPressed: busy ? null : _send,
                        icon: busy
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.onPrimary,
                                ),
                              )
                            : const Icon(Icons.arrow_upward),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
