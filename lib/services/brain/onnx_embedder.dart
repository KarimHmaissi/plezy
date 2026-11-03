import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:plezy_brain/plezy_brain.dart';

import '../../utils/app_logger.dart';

/// Fork: one file of the embedding model, pinned by revision and checked by
/// SHA-256 so a changed or truncated download is never used.
class ModelFile {
  const ModelFile(this.name, this.url, this.sha256, this.bytes);
  final String name;
  final String url;
  final String sha256;
  final int bytes;
}

/// Fork: bge-small-en-v1.5 (384 dimensions) as ONNX, downloaded once to the
/// app's support folder on a host (Mac, PC, TV); phones never need it.
abstract final class BgeSmallModel {
  static const String _base =
      'https://huggingface.co/Qdrant/bge-small-en-v1.5-onnx-Q/resolve/aa8f8b060edb00e03bfdd08813a2949946c8ba55';

  static const ModelFile model = ModelFile(
    'model_optimized.onnx',
    '$_base/model_optimized.onnx',
    '51f1bd0addd6e859e42c2c8021a5e5461385bb676a649f4b269aa445449f2431',
    66465124,
  );
  static const ModelFile tokenizer = ModelFile(
    'tokenizer.json',
    '$_base/tokenizer.json',
    'd241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66',
    711396,
  );

  /// The model files in [folder], downloading any that are missing or
  /// don't match their checksum.
  static Future<({File model, File tokenizer})> ensure(Directory folder, {http.Client? client}) async {
    await folder.create(recursive: true);
    final http.Client c = client ?? http.Client();
    try {
      return (model: await _ensure(folder, model, c), tokenizer: await _ensure(folder, tokenizer, c));
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<File> _ensure(Directory folder, ModelFile f, http.Client client) async {
    final file = File(p.join(folder.path, f.name));
    if (await file.exists() && await file.length() == f.bytes && await _sha256(file) == f.sha256) return file;
    appLogger.i('Brain: downloading ${f.name} (${(f.bytes / 1e6).toStringAsFixed(0)} MB)');
    final tmp = File('${file.path}.download');
    final response = await client.send(http.Request('GET', Uri.parse(f.url)));
    if (response.statusCode != 200) throw HttpException('Model download failed: HTTP ${response.statusCode}');
    final sink = tmp.openWrite();
    try {
      await response.stream.pipe(sink);
    } catch (_) {
      await sink.close();
      rethrow;
    }
    if (await _sha256(tmp) != f.sha256) {
      await tmp.delete();
      throw StateError('Model download for ${f.name} failed its checksum');
    }
    return tmp.rename(file.path);
  }

  static Future<String> _sha256(File file) async => (await sha256.bind(file.openRead()).first).toString();
}

/// Fork: [Embedder] on ONNX Runtime through flutter_onnxruntime (CPU on
/// macOS, Android TVs and Windows PCs). Tokenising and
/// pooling are the brain's; this only runs the model.
class OnnxEmbedder implements Embedder {
  OnnxEmbedder._(this._session, this._inner);

  /// Load the model from [folder] (see [BgeSmallModel.ensure]). [threads]
  /// caps ONNX Runtime's CPU use, so indexing never starves playback or UI.
  static Future<OnnxEmbedder> open(Directory folder, {int? threads}) async {
    final files = await BgeSmallModel.ensure(folder);
    final tokenizer = WordPieceTokenizer.fromJson(await files.tokenizer.readAsString(), maxLength: 256);
    final session = await OnnxRuntime().createSession(
      files.model.path,
      options: OrtSessionOptions(
        intraOpNumThreads: threads ?? max(1, Platform.numberOfProcessors ~/ 2),
        interOpNumThreads: 1,
      ),
    );
    late final OnnxEmbedder self;
    final inner = TransformerEmbedder.bgeSmall(tokenizer: tokenizer, run: (b) => self._run(b));
    return self = OnnxEmbedder._(session, inner);
  }

  final OrtSession _session;
  final TransformerEmbedder _inner;

  @override
  String get modelId => _inner.modelId;
  @override
  int get dimensions => _inner.dimensions;

  @override
  Future<List<Float32List>> embed(List<String> texts, {bool query = false}) => _inner.embed(texts, query: query);

  Future<Float32List> _run(TokenBatch batch) async {
    final shape = [batch.rows, batch.length];
    final inputs = <String, OrtValue>{
      'input_ids': await OrtValue.fromList(Int64List.fromList(batch.ids), shape),
      'attention_mask': await OrtValue.fromList(Int64List.fromList(batch.mask), shape),
      if (_session.inputNames.contains('token_type_ids'))
        'token_type_ids': await OrtValue.fromList(Int64List.fromList(batch.typeIds), shape),
    };
    Map<String, OrtValue> outputs = const {};
    try {
      outputs = await _session.run(inputs);
      final hidden = outputs['last_hidden_state'] ?? outputs.values.first;
      final flat = await hidden.asFlattenedList();
      return Float32List.fromList([for (final x in flat) (x as num).toDouble()]);
    } finally {
      for (final v in [...inputs.values, ...outputs.values]) {
        unawaited(v.dispose());
      }
    }
  }

  Future<void> close() => _session.close();
}
