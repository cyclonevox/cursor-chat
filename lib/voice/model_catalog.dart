class SttModelFile {
  const SttModelFile({
    required this.name,
    required this.minBytes,
    required this.urls,
  });

  final String name;
  final int minBytes;
  final List<String> urls;
}

class LocalSttModel {
  const LocalSttModel({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.sizeLabel,
    required this.ramHint,
    required this.streaming,
    required this.kind,
    required this.hfRepo,
    required this.files,
    this.needsVad = false,
  });

  final String id;
  final String title;
  final String subtitle;
  final String sizeLabel;
  final String ramHint;
  final bool streaming;
  final LocalSttKind kind;
  final String hfRepo;
  final List<SttModelFile> files;
  final bool needsVad;
}

enum LocalSttKind { senseVoice, zipformerTransducer, zipformerCtc }

String _hf(String repo, String file) =>
    'https://huggingface.co/$repo/resolve/main/$file';

String _mirror(String repo, String file) =>
    'https://hf-mirror.com/$repo/resolve/main/$file';

List<String> _fileUrls(String repo, String file) => [
  _hf(repo, file),
  _mirror(repo, file),
];

const kVadModelId = 'silero-vad';

final vadFiles = [
  SttModelFile(
    name: 'silero_vad.onnx',
    minBytes: 200000,
    urls: const [
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
      'https://hf-mirror.com/csukuangfj/silero-vad/resolve/main/silero_vad.onnx',
    ],
  ),
];

const kSenseVoiceRepo =
    'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17';
const kZipformerLargeRepo =
    'csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30';
const kZipformerSmallRepo =
    'csukuangfj/sherpa-onnx-streaming-zipformer-small-ctc-zh-int8-2025-04-01';

final localSttModels = <LocalSttModel>[
  LocalSttModel(
    id: 'sensevoice',
    title: '更准',
    subtitle: 'SenseVoice Small int8。普通话 / 粤语 / 英日韩。说完出字。',
    sizeLabel: '约 230MB',
    ramHint: '建议 6GB 内存',
    streaming: false,
    kind: LocalSttKind.senseVoice,
    hfRepo: kSenseVoiceRepo,
    needsVad: true,
    files: [
      SttModelFile(
        name: 'model.int8.onnx',
        minBytes: 80 * 1024 * 1024,
        urls: _fileUrls(kSenseVoiceRepo, 'model.int8.onnx'),
      ),
      SttModelFile(
        name: 'tokens.txt',
        minBytes: 1000,
        urls: _fileUrls(kSenseVoiceRepo, 'tokens.txt'),
      ),
    ],
  ),
  LocalSttModel(
    id: 'zipformer-large',
    title: '更跟手',
    subtitle: 'Zipformer 中文 2025-06 large int8。边说边出字。',
    sizeLabel: '约 168MB',
    ramHint: '建议 6GB 内存',
    streaming: true,
    kind: LocalSttKind.zipformerTransducer,
    hfRepo: kZipformerLargeRepo,
    files: [
      SttModelFile(
        name: 'encoder.int8.onnx',
        minBytes: 80 * 1024 * 1024,
        urls: _fileUrls(kZipformerLargeRepo, 'encoder.int8.onnx'),
      ),
      SttModelFile(
        name: 'decoder.onnx',
        minBytes: 1024 * 1024,
        urls: _fileUrls(kZipformerLargeRepo, 'decoder.onnx'),
      ),
      SttModelFile(
        name: 'joiner.int8.onnx',
        minBytes: 200000,
        urls: _fileUrls(kZipformerLargeRepo, 'joiner.int8.onnx'),
      ),
      SttModelFile(
        name: 'tokens.txt',
        minBytes: 1000,
        urls: _fileUrls(kZipformerLargeRepo, 'tokens.txt'),
      ),
    ],
  ),
  LocalSttModel(
    id: 'zipformer-small',
    title: '省资源',
    subtitle: 'Zipformer small CTC int8。弱机短句普通话。',
    sizeLabel: '约 26MB',
    ramHint: '4GB 也可试',
    streaming: true,
    kind: LocalSttKind.zipformerCtc,
    hfRepo: kZipformerSmallRepo,
    files: [
      SttModelFile(
        name: 'model.int8.onnx',
        minBytes: 10 * 1024 * 1024,
        urls: _fileUrls(kZipformerSmallRepo, 'model.int8.onnx'),
      ),
      SttModelFile(
        name: 'tokens.txt',
        minBytes: 1000,
        urls: _fileUrls(kZipformerSmallRepo, 'tokens.txt'),
      ),
    ],
  ),
];

LocalSttModel? localSttById(String id) {
  for (final m in localSttModels) {
    if (m.id == id) return m;
  }
  return null;
}
