import 'dart:typed_data';

Uint8List pcm16ToWav(
  Uint8List pcm, {
  int sampleRate = 16000,
  int channels = 1,
}) {
  final dataSize = pcm.length;
  final bytes = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add(_u32(36 + dataSize))
    ..add('WAVE'.codeUnits)
    ..add('fmt '.codeUnits)
    ..add(_u32(16))
    ..add(_u16(1))
    ..add(_u16(channels))
    ..add(_u32(sampleRate))
    ..add(_u32(sampleRate * channels * 2))
    ..add(_u16(channels * 2))
    ..add(_u16(16))
    ..add('data'.codeUnits)
    ..add(_u32(dataSize))
    ..add(pcm);
  return bytes.toBytes();
}

Float32List pcm16ToFloat32(Uint8List pcm) {
  final n = pcm.length ~/ 2;
  final out = Float32List(n);
  final bd = ByteData.sublistView(pcm);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

List<int> _u16(int v) => [v & 0xff, (v >> 8) & 0xff];

List<int> _u32(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];
