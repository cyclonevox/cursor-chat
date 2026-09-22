import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../run_log.dart';
import '../store.dart';
import '../widgets/frosted.dart';

class RunLogPage extends StatefulWidget {
  const RunLogPage({super.key, required this.store});

  final ChatStore store;

  @override
  State<RunLogPage> createState() => _RunLogPageState();
}

class _RunLogPageState extends State<RunLogPage> {
  String? _exportPath;
  String? _status;

  RunLog get log => widget.store.runLog;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPath());
  }

  Future<void> _loadPath() async {
    final file = await log.exportFile();
    if (!mounted) return;
    setState(() => _exportPath = file.path);
  }

  Future<void> _export() async {
    try {
      final path = await widget.store.exportRunLog();
      if (!mounted) return;
      setState(() {
        _exportPath = path;
        _status = '已导出';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '导出失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        flexibleSpace: const FrostedBar(),
        title: const Text('运行记录'),
        actions: [
          IconButton(
            key: const Key('export-run-log'),
            tooltip: '导出',
            onPressed: _export,
            icon: const Icon(Icons.save_alt),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: log.clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          final entries = log.entries.reversed.toList();
          return ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
              16,
              24,
            ),
            children: [
              Text('导出文件', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              SelectableText(
                _exportPath ?? '正在定位…',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                '点右上角导出，会写成下面这个 txt。调试时直接打开它。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_status != null) ...[
                const SizedBox(height: 8),
                Text(_status!, style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 16),
              if (entries.isEmpty)
                Text(
                  '还没有记录。发一条消息后再来看。',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                for (final entry in entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: entry.isError
                            ? scheme.errorContainer.withValues(alpha: 0.55)
                            : scheme.surfaceContainerHighest.withValues(
                                alpha: 0.45,
                              ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          entry.formatLine(),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  final path = _exportPath;
                  if (path == null) return;
                  await Clipboard.setData(ClipboardData(text: path));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('路径已复制')));
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制路径'),
              ),
            ],
          );
        },
      ),
    );
  }
}
