import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'models/models.dart';
import 'store.dart';
import 'widgets/answer_body.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    const seed = Color(0xFF10A37F);
    return MaterialApp(
      title: 'Cursor Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
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
        return Scaffold(
          drawer: ConversationDrawer(store: store),
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(conv?.title ?? 'Cursor Chat'),
                if (store.models.isNotEmpty)
                  Text(
                    store.modelSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
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
          body: Column(
            children: [
              if (store.apiKey.trim().isEmpty)
                MaterialBanner(
                  content: const Text('先在设置里填入 Cursor API Key，才能发消息。'),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SettingsPage(store: store),
                          ),
                        );
                      },
                      child: const Text('去设置'),
                    ),
                  ],
                ),
              if (store.error != null)
                Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            store.error!,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: store.clearError,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(child: _MessageList(store: store)),
              Composer(store: store),
            ],
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
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_square),
              title: const Text('新对话'),
              onTap: () {
                store.newChat();
                Navigator.pop(context);
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: store.conversations.length,
                itemBuilder: (context, i) {
                  final c = store.conversations[i];
                  final selected = c.id == store.active?.id;
                  return ListTile(
                    selected: selected,
                    title: Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '有问题就问，也可以拍照。\n拍题、日常问答、工作上都行。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: messages.length,
      itemBuilder: (context, i) =>
          _Bubble(key: ValueKey(messages[i].id), message: messages[i]),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.86,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isUser
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
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
                  else
                    AnswerBody(text: message.text.isEmpty ? '…' : message.text),
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
    return Theme(
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
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
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
            toolbarColor: const Color(0xFF10A37F),
            toolbarWidgetColor: Colors.white,
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_images.isNotEmpty)
              SizedBox(
                height: 72,
                child: ListView.separated(
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
                              borderRadius: BorderRadius.circular(8),
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
                  icon: const Icon(Icons.image_outlined),
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
                    controller: _controller,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: TextInputAction.newline,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      hintText: '问点什么…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) {
                      if (!busy) _send();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: busy ? null : _send,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_upward),
                ),
              ],
            ),
          ],
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
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
