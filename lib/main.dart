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
import 'store.dart';
import 'theme.dart';
import 'widgets/answer_body.dart';
import 'widgets/frosted.dart';

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
                                  color: scheme.outline.withValues(alpha: 0.25),
                                ),
                              ),
                              child: MaterialBanner(
                                backgroundColor: Colors.transparent,
                                surfaceTintColor: Colors.transparent,
                                dividerColor: Colors.transparent,
                                content: const Text(
                                  '先在设置里填入 Cursor API Key，才能发消息。',
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
              Divider(height: 1, color: scheme.outline.withValues(alpha: 0.3)),
              Expanded(
                child: ListView.builder(
                  itemCount: store.conversations.length,
                  itemBuilder: (context, i) {
                    final c = store.conversations[i];
                    final selected = c.id == store.active?.id;
                    return ListTile(
                      selected: selected,
                      selectedTileColor: scheme.primary.withValues(alpha: 0.14),
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

class _MessageList extends StatelessWidget {
  const _MessageList({required this.store});

  final ChatStore store;

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
    return SelectionArea(
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(16, topPad, 16, 132),
        itemCount: messages.length,
        itemBuilder: (context, i) => _Bubble(
          key: ValueKey(messages[i].id),
          message: messages[i],
          store: store,
          showRetry:
              i == messages.length - 1 &&
              messages[i].role == 'assistant' &&
              store.canRetryLast,
        ),
      ),
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
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                File(path),
                                height: 140,
                                fit: BoxFit.cover,
                              ),
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
                                icon: const Icon(
                                  Icons.copy_outlined,
                                  size: 18,
                                ),
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
  final _picker = ImagePicker();
  final List<PromptImage> _images = [];
  bool _picking = false;

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
    _controller.dispose();
    super.dispose();
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
                      onPressed: busy
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
                    if (!Platform.isLinux)
                      IconButton(
                        tooltip: '拍照',
                        onPressed: busy
                            ? null
                            : () => _addFromPicker(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined),
                      ),
                    Expanded(
                      child: TextField(
                        key: const Key('composer-input'),
                        controller: _controller,
                        minLines: 1,
                        maxLines: 6,
                        textInputAction: TextInputAction.newline,
                        enabled: !busy,
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
                    const SizedBox(width: 4),
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

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});

  final ChatStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _key;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: widget.store.apiKey);
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        flexibleSpace: const FrostedBar(),
        title: const Text('设置'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 16,
          16,
          32,
        ),
        children: [
          const Text('Cursor API Key'),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            obscureText: true,
            decoration: const InputDecoration(
              hintText: 'cursor_…',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => widget.store.apiKey = v,
          ),
          const SizedBox(height: 8),
          Text(
            '在 cursor.com/dashboard/api 创建。只存在这台设备上。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          const Text('模型'),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: widget.store,
            builder: (context, _) {
              final models = widget.store.models;
              if (widget.store.loadingModels) {
                return const LinearProgressIndicator();
              }
              if (models.isEmpty) {
                return const Text('保存 Key 后会自动拉取可用模型。');
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownMenu<String>(
                    key: ValueKey('model-${widget.store.modelId}'),
                    expandedInsets: EdgeInsets.zero,
                    initialSelection:
                        models.any((m) => m.id == widget.store.modelId)
                        ? widget.store.modelId
                        : models.first.id,
                    dropdownMenuEntries: [
                      for (final m in models)
                        DropdownMenuEntry(
                          value: m.id,
                          label: m.displayName,
                          trailingIcon: m.parameters.isEmpty
                              ? null
                              : Text(
                                  m.parameters.map((p) => p.label).join(' · '),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                        ),
                    ],
                    onSelected: (v) {
                      if (v == null) return;
                      widget.store.selectModel(v, persist: false);
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '换模型后，下面只出现这个模型目录里有的参数。思考档不一致的不会硬套。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  ..._paramPickers(context, widget.store),
                ],
              );
            },
          ),
          Text(
            '已开始的对话沿用当时的模型；改档位后请开新对话。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () async {
              widget.store.apiKey = _key.text;
              await widget.store.saveSettings();
              await widget.store.refreshModels();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

List<Widget> _paramPickers(BuildContext context, ChatStore store) {
  final model = store.selectedModel;
  if (model == null) return const [];
  if (model.parameters.isEmpty) {
    return [
      Text(
        '${model.displayName} 没有 Fast / 思考强度参数。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }
  return [
    for (final p in model.parameters) ...[
      const SizedBox(height: 12),
      Text(p.label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in p.values)
            ChoiceChip(
              label: Text(v.label),
              selected: store.modelParams[p.id] == v.value,
              onSelected: (_) => store.setParam(p.id, v.value),
            ),
        ],
      ),
    ],
  ];
}
