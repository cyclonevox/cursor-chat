import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/cursor_api.dart';
import '../store.dart';
import '../voice/device_profile.dart';
import '../voice/model_catalog.dart';
import '../voice/voice_settings.dart';
import '../widgets/frosted.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});

  final ChatStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _key;
  late final Listenable _listen;
  SttRecommendation? _recommend;
  final Map<String, TextEditingController> _cloudFields = {};

  ChatStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: store.apiKey);
    _listen = Listenable.merge([store, store.modelStore]);
    unawaited(_loadRecommend());
  }

  Future<void> _loadRecommend() async {
    final rec = await recommendLocalModel();
    if (!mounted) return;
    setState(() => _recommend = rec);
  }

  @override
  void dispose() {
    _key.dispose();
    for (final c in _cloudFields.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _cloudCtrl(String provider, String field) {
    final id = '$provider.$field';
    return _cloudFields.putIfAbsent(
      id,
      () => TextEditingController(
        text: secretField(store.cloudSecret(provider), field),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        flexibleSpace: const FrostedBar(),
        title: const Text('设置'),
      ),
      body: ListenableBuilder(
        listenable: _listen,
        builder: (context, _) {
          return ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + kToolbarHeight + 16,
              16,
              32,
            ),
            children: [
              Text('Cursor', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              const Text('Cursor API Key'),
              const SizedBox(height: 8),
              TextField(
                controller: _key,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: 'cursor_…',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => store.apiKey = v,
              ),
              const SizedBox(height: 16),
              Text('怎么拿到 Key', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Text(
                '1. 用能登录 Cursor 的账号，在浏览器打开这个页面：',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              SelectableText(
                kCursorApiKeyUrl,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('copy-api-key-url'),
                  onPressed: () async {
                    await Clipboard.setData(
                      const ClipboardData(text: kCursorApiKeyUrl),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('网址已复制，去浏览器打开'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('复制网址'),
                ),
              ),
              Text(
                '2. 点 Create API Key，复制以 cursor_ 开头的那一串。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              Text(
                '3. 粘贴到上面。Key 只存在这台设备上。没有 Cursor 账号，或账号还不能用 Cloud Agents，网页上会创建失败。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              const Text('模型'),
              const SizedBox(height: 8),
              ..._modelSection(context),
              Text(
                '已开始的对话沿用当时的模型；改档位后请开新对话。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                '已经有模型列表就不必反复去拉。换了 Key，或想更新目录，再点保存并刷新。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: store.loadingModels
                    ? null
                    : () async {
                        store.apiKey = _key.text;
                        await store.saveSettings();
                        await store.refreshModels(force: true);
                        if (!context.mounted) return;
                        if (store.models.isNotEmpty) {
                          if (store.modelsError != null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(store.modelsError!)),
                            );
                          }
                          Navigator.pop(context);
                        }
                      },
                child: Text(store.loadingModels ? '正在刷新…' : '保存并刷新模型'),
              ),
              const SizedBox(height: 32),
              Text('语音输入', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '配好并就绪后，对话输入框发送左侧才会出现麦克风。默认关闭。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mode in [
                    VoiceMode.off,
                    if (Platform.isAndroid) VoiceMode.system,
                    VoiceMode.local,
                    VoiceMode.cloud,
                  ])
                    ChoiceChip(
                      key: Key('voice-mode-${mode.id}'),
                      label: Text(mode.label),
                      selected: store.voiceMode == mode,
                      onSelected: (_) => store.setVoiceMode(mode),
                    ),
                ],
              ),
              if (!Platform.isAndroid) ...[
                const SizedBox(height: 8),
                Text(
                  '系统听写是手机系统自带的识别，Linux 上没有这一项。本机模型和云端听写都可以用，模型和 Android 是同一套。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (store.voiceMode == VoiceMode.system) ...[
                const SizedBox(height: 16),
                Text(
                  '使用系统自带识别，不另占空间。准度取决于手机语音包。选中后即可使用麦克风。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (store.voiceMode == VoiceMode.local) ..._localSection(context),
              if (store.voiceMode == VoiceMode.cloud) ..._cloudSection(context),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _modelSection(BuildContext context) {
    final models = store.models;
    if (models.isEmpty) {
      if (store.loadingModels) {
        return const [LinearProgressIndicator()];
      }
      return [
        Text(
          store.modelsError ?? '点下面保存并刷新，会去拉可用模型；失败会自动再试。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ];
    }
    return [
      if (store.loadingModels)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: LinearProgressIndicator(),
        ),
      if (store.modelsError != null) ...[
        Text(
          store.modelsError!,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.error,
          ),
        ),
        const SizedBox(height: 8),
      ],
      DropdownMenu<String>(
        key: ValueKey('model-${store.modelId}'),
        expandedInsets: EdgeInsets.zero,
        initialSelection: models.any((m) => m.id == store.modelId)
            ? store.modelId
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
          store.selectModel(v, persist: false);
        },
      ),
      const SizedBox(height: 16),
      Text(
        '换模型后，下面只出现这个模型目录里有的参数。思考档不一致的不会硬套。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      ..._paramPickers(context, store),
    ];
  }

  List<Widget> _localSection(BuildContext context) {
    final rec = _recommend;
    return [
      const SizedBox(height: 16),
      if (rec != null)
        Text(rec.reason, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      for (final m in localSttModels) _localCard(context, m, rec?.id),
    ];
  }

  Widget _localCard(
    BuildContext context,
    LocalSttModel model,
    String? recommendedId,
  ) {
    final ready = store.modelStore.isReady(model.id);
    final selected = store.localSttId == model.id;
    final progress = store.modelStore.progressFor(model.id);
    final suggested = recommendedId == model.id;
    return Card(
      key: Key('local-stt-${model.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    model.title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (suggested)
                  const Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('本机建议'),
                  ),
                if (ready)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.check_circle, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(model.subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              '${model.sizeLabel} · ${model.ramHint} · ${model.streaming ? '边说边出字' : '说完出字'}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            if (progress?.busy == true) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress!.fraction),
            ],
            if (progress?.error != null) ...[
              const SizedBox(height: 8),
              Text(
                progress!.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (!ready && progress?.busy == true)
                  TextButton(
                    key: Key('pause-stt-${model.id}'),
                    onPressed: () => store.cancelLocalSttDownload(model.id),
                    child: const Text('暂停'),
                  )
                else if (!ready)
                  FilledButton.tonal(
                    key: Key('download-stt-${model.id}'),
                    onPressed: () async {
                      try {
                        await store.downloadLocalStt(model.id);
                      } catch (e) {
                        if (!context.mounted) return;
                        final msg = '$e';
                        if (msg.contains('已暂停')) return;
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(msg)));
                      }
                    },
                    child: Text(progress?.error != null ? '重试' : '下载'),
                  )
                else
                  TextButton(
                    onPressed: () => store.deleteLocalStt(model.id),
                    child: const Text('删除'),
                  ),
                ChoiceChip(
                  key: Key('select-stt-${model.id}'),
                  label: const Text('选用'),
                  selected: selected,
                  onSelected: ready
                      ? (_) => store.setLocalSttId(model.id)
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _cloudSection(BuildContext context) {
    final provider =
        cloudProviderById(store.cloudSttProvider) ?? cloudSttProviders.first;
    return [
      const SizedBox(height: 16),
      Text('测试功能：接口已接通，识别效果未验证。', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      DropdownMenu<String>(
        key: ValueKey('cloud-${store.cloudSttProvider}'),
        expandedInsets: EdgeInsets.zero,
        initialSelection: provider.id,
        dropdownMenuEntries: [
          for (final p in cloudSttProviders)
            DropdownMenuEntry(value: p.id, label: p.label),
        ],
        onSelected: (v) {
          if (v == null) return;
          store.setCloudSttProvider(v);
        },
      ),
      const SizedBox(height: 8),
      Text(provider.hint, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      for (final field in provider.fields) ...[
        TextField(
          key: Key('cloud-field-${provider.id}-${field.key}'),
          controller: _cloudCtrl(provider.id, field.key),
          obscureText: field.obscure,
          decoration: InputDecoration(
            labelText: field.label,
            border: const OutlineInputBorder(),
          ),
          onChanged: (v) {
            store.setCloudSecret(
              provider.id,
              withSecretField(store.cloudSecret(provider.id), field.key, v),
            );
          },
        ),
        const SizedBox(height: 12),
      ],
    ];
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
