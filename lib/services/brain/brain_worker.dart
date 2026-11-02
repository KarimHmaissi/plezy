import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:plezy_brain/plezy_brain.dart';

import 'history_brain.dart' show TransformerEmbedderIds;
import 'onnx_embedder.dart';

/// Fork: the history brain's own isolate. Embedding (tokenising, hashing
/// profile text, the ONNX model) and vector search run here, so the app's
/// isolate never stalls on them; it only sends requests and gets ids back.
///
/// Opens its own connection to the brain's database (WAL, so the app keeps
/// reading while this writes vectors).
class BrainWorker {
  BrainWorker._(this._isolate, this._port);

  final Isolate _isolate;
  final SendPort _port;

  /// Null where background isolates can't reach plugins (tests): the brain
  /// then runs this work in-process.
  static Future<BrainWorker?> spawn({required String dbPath, required String modelDir}) async {
    final token = RootIsolateToken.instance;
    if (token == null) return null;
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_main, (ready.sendPort, dbPath, modelDir, token), debugName: 'brain');
    final port = await ready.first as SendPort;
    ready.close();
    return BrainWorker._(isolate, port);
  }

  Future<Object?> _call(String op, [Map<String, Object?> args = const {}]) async {
    final reply = ReceivePort();
    _port.send((op, args, reply.sendPort));
    final result = await reply.first;
    reply.close();
    if (result case ('error', final String message)) throw StateError(message);
    return result;
  }

  /// Embed what's left ([BrainIndexer.run]); [pause] while it should wait.
  Future<BrainIndexSummary> index({required int batchSize, required double duty}) async {
    final r = await _call('index', {'batchSize': batchSize, 'duty': duty}) as Map;
    return (
      embedded: r['embedded'] as int,
      remaining: r['remaining'] as int,
      took: Duration(microseconds: r['took'] as int),
      stopped: r['stopped'] as bool,
    );
  }

  /// Open the model and load the vectors now, so the first search is quick.
  Future<void> warm() => _call('warm');

  void pause(bool paused) => _port.send(('pause', {'on': paused}, null));

  /// Profiles changed on another connection: re-read vectors and flags.
  void reload() => _port.send(('reload', const <String, Object?>{}, null));

  Future<List<BrainHit>> searchText(
    String text, {
    int limit = 20,
    bool? watched,
    TitleKind? kind,
    Set<String>? ids,
  }) async =>
      _hits(await _call('searchText', {'text': text, 'limit': limit, 'watched': watched, 'kind': kind, 'ids': ids}));

  Future<List<BrainHit>> similar(String id, {int limit = 20, bool? watched, TitleKind? kind}) async =>
      _hits(await _call('similar', {'id': id, 'limit': limit, 'watched': watched, 'kind': kind}));

  static List<BrainHit> _hits(Object? r) => [for (final h in r as List) (id: h.$1 as String, score: h.$2 as double)];

  void close() {
    _port.send(('close', const <String, Object?>{}, null));
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  static Future<void> _main((SendPort, String, String, RootIsolateToken) setup) async {
    final (ready, dbPath, modelDir, token) = setup;
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    final store = BrainStore.open(dbPath);
    Future<OnnxEmbedder>? embedder;
    Future<OnnxEmbedder> embedderNow() async {
      try {
        return await (embedder ??= OnnxEmbedder.open(Directory(modelDir), threads: 1));
      } catch (_) {
        embedder = null;
        rethrow;
      }
    }

    var paused = false;
    final port = ReceivePort();
    ready.send(port.sendPort);

    await for (final message in port) {
      final (op, args, reply) = message as (String, Map<String, Object?>, SendPort?);
      // Each request runs on its own: a search answers while an index run rests.
      unawaited(() async {
        try {
          final Object? result = switch (op) {
            'pause' => paused = args['on'] as bool,
            'reload' => _run(store.reload),
            'warm' => await () async {
              final e = await embedderNow();
              await e.embed(['warm up'], query: true);
              // Loads the vector cache (an unknown id finds nothing).
              store.similar(e.modelId, '', limit: 1);
              return null;
            }(),
            'close' => _run(store.close),
            'index' => await () async {
              final r = await BrainIndexer(
                store: store,
                embedder: await embedderNow(),
                batchSize: args['batchSize'] as int,
                duty: args['duty'] as double,
                shouldPause: () => paused,
              ).run();
              return {
                'embedded': r.embedded,
                'remaining': r.remaining,
                'took': r.took.inMicroseconds,
                'stopped': r.stopped,
              };
            }(),
            'searchText' => await () async {
              final e = await embedderNow();
              final query = (await e.embed([args['text'] as String], query: true)).single;
              return [
                for (final h in store.search(
                  e.modelId,
                  query,
                  limit: args['limit'] as int,
                  watched: args['watched'] as bool?,
                  kind: args['kind'] as TitleKind?,
                  ids: args['ids'] as Set<String>?,
                ))
                  (h.id, h.score),
              ];
            }(),
            'similar' => [
              for (final h in store.similar(
                TransformerEmbedderIds.bgeSmall,
                args['id'] as String,
                limit: args['limit'] as int,
                watched: args['watched'] as bool?,
                kind: args['kind'] as TitleKind?,
              ))
                (h.id, h.score),
            ],
            _ => throw ArgumentError('Unknown brain op $op'),
          };
          reply?.send(result);
        } catch (e) {
          reply?.send(('error', '$e'));
        }
      }());
      if (op == 'close') break;
    }
    port.close();
  }

  static Null _run(void Function() action) {
    action();
    return null;
  }
}
