import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';

class DownloadProgress {
  const DownloadProgress({
    required this.id,
    this.received = 0,
    this.total = 0,
    this.error,
    this.busy = false,
  });

  final String id;
  final int received;
  final int total;
  final String? error;
  final bool busy;

  double? get fraction {
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }
}

/// Integration tests can rewrite catalog URLs to a host HTTP server.
String Function(String url)? debugRewriteDownloadUrl;

class ModelStore extends ChangeNotifier {
  ModelStore({http.Client? client, this._documents})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Future<Directory> Function()? _documents;
  final Map<String, DownloadProgress> _progress = {};
  Directory? _root;
  final Set<String> _readyCache = {};
  final Set<String> _cancel = {};

  /// Tests can shrink size checks so they do not write 80MB dummy weights.
  @visibleForTesting
  int Function(String id, String name)? minBytesOverride;

  DownloadProgress? progressFor(String id) => _progress[id];

  Future<Directory> rootDir() async {
    if (_root != null) return _root!;
    final docs = _documents != null
        ? await _documents()
        : await getApplicationDocumentsDirectory();
    _root = Directory('${docs.path}/stt');
    await _root!.create(recursive: true);
    return _root!;
  }

  Directory modelDirSync(Directory root, String id) =>
      Directory('${root.path}/$id');

  Future<Directory> modelDir(String id) async {
    final dir = modelDirSync(await rootDir(), id);
    await dir.create(recursive: true);
    return dir;
  }

  bool isReady(String id) {
    if (_readyCache.contains(id)) return true;
    final root = _root;
    if (root == null) return false;
    return _checkReady(root, id);
  }

  Future<bool> refreshReady(String id) async {
    final root = await rootDir();
    final ok = _checkReady(root, id);
    if (ok) {
      _readyCache.add(id);
    } else {
      _readyCache.remove(id);
    }
    notifyListeners();
    return ok;
  }

  Future<void> refreshAll() async {
    await rootDir();
    for (final m in localSttModels) {
      await refreshReady(m.id);
    }
    await refreshReady(kVadModelId);
  }

  bool _checkReady(Directory root, String id) {
    if (id == kVadModelId) {
      return _filesReady(modelDirSync(root, id), vadFiles, id: id);
    }
    final model = localSttById(id);
    if (model == null) return false;
    if (!_filesReady(modelDirSync(root, id), model.files, id: id)) {
      return false;
    }
    if (model.needsVad &&
        !_filesReady(
          modelDirSync(root, kVadModelId),
          vadFiles,
          id: kVadModelId,
        )) {
      return false;
    }
    return true;
  }

  int _minBytes(String id, SttModelFile f) =>
      minBytesOverride?.call(id, f.name) ?? f.minBytes;

  bool _filesReady(Directory dir, List<SttModelFile> files, {String id = ''}) {
    for (final f in files) {
      final file = File('${dir.path}/${f.name}');
      if (!file.existsSync()) return false;
      if (file.lengthSync() < _minBytes(id, f)) return false;
    }
    return true;
  }

  Future<String> filePath(String modelId, String name) async {
    final dir = await modelDir(modelId);
    return '${dir.path}/$name';
  }

  Future<void> deleteModel(String id) async {
    final dir = await modelDir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
    _readyCache.remove(id);
    if (id != kVadModelId) {
      // Keep VAD; other models may still need it.
    }
    _progress.remove(id);
    notifyListeners();
  }

  Future<void> cancelDownload(String id) async {
    _cancel.add(id);
    if (id != kVadModelId) _cancel.add(kVadModelId);
  }

  Future<void> download(String id) async {
    if (id == kVadModelId) {
      await _downloadFiles(id, vadFiles);
      return;
    }
    final model = localSttById(id);
    if (model == null) throw StateError('unknown model $id');
    if (model.needsVad) {
      await _downloadFiles(kVadModelId, vadFiles);
    }
    await _downloadFiles(id, model.files);
  }

  Future<void> _downloadFiles(String id, List<SttModelFile> files) async {
    _cancel.remove(id);
    _progress[id] = DownloadProgress(id: id, busy: true);
    notifyListeners();
    try {
      final dir = await modelDir(id);
      var receivedAll = 0;
      var totalAll = 0;
      for (final f in files) {
        totalAll += _minBytes(id, f);
      }
      for (final f in files) {
        if (_cancel.contains(id)) {
          throw HttpException('已暂停');
        }
        final dest = File('${dir.path}/${f.name}');
        if (dest.existsSync() && dest.lengthSync() >= _minBytes(id, f)) {
          receivedAll += dest.lengthSync();
          _progress[id] = DownloadProgress(
            id: id,
            busy: true,
            received: receivedAll,
            total: totalAll,
          );
          notifyListeners();
          continue;
        }
        final tmp = File('${dest.path}.part');
        await _downloadOne(id, f, tmp, (n, t) {
          _progress[id] = DownloadProgress(
            id: id,
            busy: true,
            received: receivedAll + n,
            total: totalAll > t ? totalAll : receivedAll + t,
          );
          notifyListeners();
        });
        if (tmp.existsSync()) {
          if (dest.existsSync()) await dest.delete();
          await tmp.rename(dest.path);
        }
        if (!dest.existsSync() || dest.lengthSync() < _minBytes(id, f)) {
          throw HttpException('下载不完整：${f.name}');
        }
        receivedAll += dest.lengthSync();
      }
      _readyCache.add(id);
      _progress[id] = DownloadProgress(
        id: id,
        busy: false,
        received: receivedAll,
        total: receivedAll,
      );
      notifyListeners();
    } catch (e) {
      _progress[id] = DownloadProgress(id: id, busy: false, error: '$e');
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _downloadOne(
    String id,
    SttModelFile file,
    File dest,
    void Function(int received, int total) onProgress,
  ) async {
    Object? last;
    for (final raw in file.urls) {
      final url = debugRewriteDownloadUrl?.call(raw) ?? raw;
      try {
        await dest.parent.create(recursive: true);
        if (dest.existsSync()) await dest.delete();
        final req = http.Request('GET', Uri.parse(url));
        final res = await _client.send(req);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          last = HttpException('HTTP ${res.statusCode} $url');
          continue;
        }
        final sink = dest.openWrite();
        var got = 0;
        final total = res.contentLength ?? _minBytes(id, file);
        try {
          await for (final chunk in res.stream) {
            if (_cancel.contains(id)) {
              await sink.close();
              if (dest.existsSync()) await dest.delete();
              throw HttpException('已暂停');
            }
            sink.add(chunk);
            got += chunk.length;
            onProgress(got, total);
          }
        } catch (e) {
          await sink.close();
          rethrow;
        }
        await sink.close();
        return;
      } catch (e) {
        last = e;
        if (e is HttpException && e.message == '已暂停') rethrow;
      }
    }
    throw last ?? HttpException('无法下载 ${file.name}');
  }
}
