import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../debug/voice_probe.dart';
import '../models/models.dart';
import '../store.dart';
import '../voice/create_engine.dart';
import '../voice/stt_engine.dart';
import '../widgets/frosted.dart';
import '../widgets/voice_listening_bar.dart';

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
  final List<double> _voicePending = [];

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      unawaited(_recoverLostCrop());
    }
    if (kVoiceUiProbe) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_startVoice());
      });
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
    _voicePending.clear();
  }

  void _beginVoiceVisual() {
    _voiceElapsed = Duration.zero;
    _voicePending.clear();
    _voiceClock?.cancel();
    _voiceClock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_listening) return;
      setState(() => _voiceElapsed += const Duration(seconds: 1));
    });
  }

  void _onVoiceLevel(double level) {
    if (!mounted || !_listening) return;
    _voicePending.add(level.clamp(0.0, 1.0));
  }

  void _hideKeyboard() {
    _focus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod('TextInput.hide'));
  }

  Future<void> _startVoice() async {
    if (_listening || _transcribing) return;
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

  Future<void> _send({bool insertNow = false}) async {
    final text = _controller.text;
    final images = List<PromptImage>.from(_images);
    if (text.trim().isEmpty && images.isEmpty) return;
    _controller.clear();
    setState(() => _images.clear());
    await widget.store.send(text: text, images: images, insertNow: insertNow);
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
                      onPressed: _listening || _transcribing
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
                        onPressed: () => _addFromPicker(ImageSource.camera),
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
                                enabled: !_listening && !_transcribing,
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
                                onSubmitted: (_) => _send(),
                              ),
                            ),
                          ),
                          if (_listening || _transcribing)
                            VoiceListeningBar(
                              key: const Key('composer-voice-meter'),
                              pending: _voicePending,
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
                        onPressed: _transcribing ? null : _cancelVoice,
                        icon: const Icon(Icons.close),
                      ),
                      IconButton.filledTonal(
                        key: const Key('composer-voice-confirm'),
                        tooltip: '完成',
                        onPressed: _transcribing ? null : _confirmVoice,
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
                        onPressed: _startVoice,
                        icon: const Icon(Icons.mic_none_outlined),
                      ),
                    if (!_listening && !_transcribing) ...[
                      if (busy)
                        IconButton(
                          key: const Key('composer-stop'),
                          tooltip: '停止',
                          onPressed: () =>
                              unawaited(widget.store.cancelGeneration()),
                          icon: const Icon(Icons.stop),
                        ),
                      Tooltip(
                        message: busy ? '加入队列 · 长按立刻问' : '发送',
                        child: GestureDetector(
                          onLongPress: busy
                              ? () => _send(insertNow: true)
                              : null,
                          child: IconButton.filled(
                            key: const Key('composer-send'),
                            tooltip: busy ? '加入队列' : '发送',
                            onPressed: () => unawaited(_send()),
                            icon: const Icon(Icons.arrow_upward),
                          ),
                        ),
                      ),
                    ],
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
