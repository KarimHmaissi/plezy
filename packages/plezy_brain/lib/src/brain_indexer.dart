import 'dart:typed_data';

import 'brain_store.dart';
import 'embedder.dart';
import 'title_profile.dart';

typedef BrainIndexSummary = ({int embedded, int remaining, Duration took, bool stopped});

/// Embeds every profile in a [BrainStore] that has no vector (or whose
/// text changed), a batch at a time, watched titles first. Resumable: it
/// only ever asks the store for what's left.
class BrainIndexer {
  BrainIndexer({
    required this.store,
    required this.embedder,
    this.batchSize = 32,
    this.gap = Duration.zero,
    this.duty = 1.0,
    this.shouldPause,
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future<void>.delayed;

  final BrainStore store;
  final Embedder embedder;
  final int batchSize;

  /// A breather between batches, so a slow device stays responsive.
  final Duration gap;

  /// The share of time spent embedding (0-1]: below 1, each batch is
  /// followed by a rest in proportion to how long it took, so a background
  /// index never pins the CPU. When batches slow down (the device is busy
  /// with something else, or hot), the rest grows with them, up to
  /// [maxSlowdown] times.
  final double duty;
  static const double maxSlowdown = 4;

  /// Asked before each batch; while true (say, during playback), it waits.
  final bool Function()? shouldPause;
  final Future<void> Function(Duration) _sleep;

  static const Duration pausePoll = Duration(seconds: 30);

  /// Embed until nothing is left, [max] titles are done, or [cancelled].
  Future<BrainIndexSummary> run({int? max, bool Function()? cancelled}) async {
    final started = DateTime.now();
    var embedded = 0;
    var stopped = false;
    while (max == null || embedded < max) {
      if (cancelled?.call() ?? false) {
        stopped = true;
        break;
      }
      if (shouldPause?.call() ?? false) {
        await _sleep(pausePoll);
        continue;
      }
      final todo = store.vectorsToUpdate(embedder.modelId, limit: batchSize);
      if (todo.isEmpty) break;
      final batchStart = DateTime.now();
      final vectors = await embedder.embed([for (final p in todo) p.embedText]);
      final took = DateTime.now().difference(batchStart);
      store.putVectors(embedder.modelId, <TitleProfile, Float32List>{for (final (i, p) in todo.indexed) p: vectors[i]});
      embedded += todo.length;
      if (gap > Duration.zero) await _sleep(gap);
      final rest = restAfter(took, todo.length);
      if (rest > Duration.zero) await _sleep(rest);
    }
    final left = store.pendingVectors(embedder.modelId);
    return (embedded: embedded, remaining: left, took: DateTime.now().difference(started), stopped: stopped);
  }

  /// Fastest time per title seen by this indexer: the device at its least busy.
  double? _fastestPerItem;

  /// How long to rest after a batch of [items] that took [took].
  Duration restAfter(Duration took, int items) {
    if (duty >= 1 || items == 0) return Duration.zero;
    final perItem = took.inMicroseconds / items;
    final best = _fastestPerItem;
    final fastest = _fastestPerItem = best == null || perItem < best ? perItem : best;
    final slowdown = (perItem / fastest).clamp(1.0, maxSlowdown);
    return Duration(microseconds: (took.inMicroseconds * (1 / duty - 1) * slowdown).round());
  }
}
