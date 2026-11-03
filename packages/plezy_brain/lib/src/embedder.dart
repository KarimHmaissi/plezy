import 'dart:math';
import 'dart:typed_data';

import 'wordpiece.dart';

/// Turns text into unit-length vectors whose dot product is their
/// similarity. The host supplies the model runtime; the brain only sees this.
abstract interface class Embedder {
  /// Names the model, so vectors from different models are never mixed.
  String get modelId;
  int get dimensions;

  /// One vector per text. [query]: short search text rather than a
  /// document (some models want a prefix for it).
  Future<List<Float32List>> embed(List<String> texts, {bool query = false});
}

/// Runs a BERT-style ONNX model on one batch and returns its
/// `last_hidden_state`, row-major ([TokenBatch.rows] × length × hidden).
typedef TransformerRunner = Future<Float32List> Function(TokenBatch batch);

/// An [Embedder] for BERT-style sentence models: tokenises here, hands the
/// batch to [run] (the host's ONNX runtime), then pools (the [CLS] token, as
/// bge does) and normalises.
class TransformerEmbedder implements Embedder {
  TransformerEmbedder({
    required this.modelId,
    required this.dimensions,
    required this.tokenizer,
    required this.run,
    this.queryPrefix = '',
    this.batchSize = 16,
  });

  /// bge-small-en-v1.5: 384 dimensions, CLS pooling, an instruction prefix
  /// for search queries.
  factory TransformerEmbedder.bgeSmall({required WordPieceTokenizer tokenizer, required TransformerRunner run}) =>
      TransformerEmbedder(
        modelId: 'bge-small-en-v1.5',
        dimensions: 384,
        tokenizer: tokenizer,
        run: run,
        queryPrefix: 'Represent this sentence for searching relevant passages: ',
      );

  @override
  final String modelId;
  @override
  final int dimensions;
  final WordPieceTokenizer tokenizer;
  final TransformerRunner run;
  final String queryPrefix;
  final int batchSize;

  @override
  Future<List<Float32List>> embed(List<String> texts, {bool query = false}) async {
    final out = <Float32List>[];
    for (var i = 0; i < texts.length; i += batchSize) {
      final slice = texts.sublist(i, min(i + batchSize, texts.length));
      final batch = tokenizer.batch([for (final t in slice) query ? '$queryPrefix$t' : t]);
      final hidden = await run(batch);
      final stride = batch.length * dimensions;
      if (hidden.length != batch.rows * stride) {
        throw StateError('Model output ${hidden.length} values, expected ${batch.rows * stride}');
      }
      for (var r = 0; r < batch.rows; r++) {
        out.add(normalise(Float32List.sublistView(hidden, r * stride, r * stride + dimensions)));
      }
    }
    return out;
  }
}

/// A unit-length copy of [v].
Float32List normalise(List<double> v) {
  var sum = 0.0;
  for (final x in v) {
    sum += x * x;
  }
  final norm = sqrt(sum);
  final out = Float32List(v.length);
  if (norm == 0) return out;
  for (var i = 0; i < v.length; i++) {
    out[i] = v[i] / norm;
  }
  return out;
}

double dot(Float32List a, Float32List b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}
