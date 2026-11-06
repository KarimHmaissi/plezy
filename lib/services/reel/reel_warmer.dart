import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import 'clip_resolver.dart';
import 'reel_controller.dart' show ReelArtPrecache, ReelTimeouts;
import 'reel_cursor.dart';
import 'reel_decks.dart';
import 'reel_library.dart';
import 'reel_store.dart';

/// A card's item from the caches alone (no server read), or null.
typedef ReelCachedItem = Future<MediaItem?> Function(String serverId, String ratingKey);

/// The warm start before the Reel opens (plan V2-14, D3 and D15), on the TV.
///
/// Armed from the app's post-startup idle point, it waits [startDelay], then
/// looks every [recheck] for a moment when the app is in the foreground, no
/// video plays ([playing]) and the Reel isn't open. It runs at most once a
/// day, and not at all on a day the Reel has already opened. In order:
///
/// 0. The Reel's daily cache sweep ([ReelStore.sweep], V2-15).
/// 1. Today's For You build, only when the Reel was used in the last
///    [usedWithin] (on this device, or on the other one through the synced
///    signals) and no pool for today is here (D3). The gather runs first;
///    the one Sonnet call follows unless playback started meanwhile. The
///    call is the Reel's own (`ReelApp`), so AiSpend records it like every
///    build.
/// 2. Today's list kept ([ForYouDeck.keepToday]): with no pool, code order
///    is worked out now and kept as `deck:for-you:<day>`.
/// 3. The card the Reel will open on (the kept cursor's, else the first) and
///    the two after it, read from the caches only: their `src:` rows and
///    their items. No server is asked. The first card's art is then decoded
///    into the image cache ([precacheArt]) when memory allows.
///
/// Step 4 of the plan (fetching the first clip's bytes before the Reel
/// opens) is not built: D15 keeps every guest-server read to the cards the
/// Reel is showing.
///
/// [ForYouDeck] is the one the Reel's own session uses, so a Reel opened
/// while a step runs joins its gather and build rather than starting its
/// own. [yieldNow] (the Reel starting) stops the steps still to come.
class ReelWarmer {
  ReelWarmer({
    required this.store,
    required this.forYou,
    required this.playing,
    this.foreground,
    this.cachedItem,
    this.precacheArt,
    this.artAllowed,
    this.startDelay = const Duration(seconds: 60),
    this.recheck = const Duration(minutes: 15),
    this.timeouts = const ReelTimeouts(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ReelStore store;
  final ForYouDeck forYou;

  /// Real playback is on (a video session is open): nothing runs.
  final bool Function() playing;

  /// The app is in the foreground; null: always.
  final bool Function()? foreground;

  /// A card's item from the caches alone; null: no art is warmed.
  final ReelCachedItem? cachedItem;

  /// Decodes a card's art as the Reel's card view will build it.
  final ReelArtPrecache? precacheArt;

  /// Memory allows warming art (no trim in force); null: always.
  final bool Function()? artAllowed;

  final Duration startDelay;
  final Duration recheck;
  final ReelTimeouts timeouts;
  final DateTime Function() _clock;

  /// D3: the build runs only for a Reel used this recently.
  static const Duration usedWithin = Duration(days: 7);

  /// How many cards step 3 reads: the one the Reel opens on and two more.
  static const int cardsAhead = 3;

  Timer? _timer;
  bool _disposed = false;
  bool _reelActive = false;

  /// Bumped by [yieldNow]: a run started before it stops at its next step.
  int _gen = 0;

  /// The day ([ReelStore.dayStamp]) the warm start ran or the Reel opened.
  String? _doneDay;

  /// The step a run is on, null when none runs.
  String? _step;

  Future<String>? _running;

  String _today() => ReelStore.dayStamp(_clock());

  /// Starts looking for a moment to run, after [startDelay]. Calling it
  /// again changes nothing.
  void arm() {
    if (_disposed || _timer != null || _running != null) return;
    _timer = Timer(startDelay, _tick);
  }

  void _tick() {
    _timer = null;
    if (_disposed) return;
    unawaited(
      _maybeRun().whenComplete(() {
        if (!_disposed && _timer == null) _timer = Timer(recheck, _tick);
      }),
    );
  }

  /// Runs today's warm start when the moment is right; null when it isn't.
  Future<String?> _maybeRun() async {
    if (_doneDay == _today() || _running != null) return null;
    final wait = _reelActive
        ? 'the Reel is open'
        : playing()
        ? 'video is playing'
        : !(foreground?.call() ?? true)
        ? 'the app is in the background'
        : null;
    if (wait != null) {
      appLogger.d('[ReelWarmer] waits: $wait');
      return null;
    }
    return run();
  }

  /// The Reel is starting (or its session was just built): the steps still
  /// to come are dropped, and nothing more runs today. A step in flight
  /// finishes on its own; the Reel joins it rather than starting another.
  void yieldNow() {
    _gen++;
    _doneDay = _today();
    final step = _step;
    if (step != null) appLogger.i('[ReelWarmer] yields to the Reel at $step');
  }

  /// The Reel's session is active or not ([ReelController.onActive]).
  void reelActive(bool on) {
    _reelActive = on;
    if (on) yieldNow();
  }

  /// One run of the steps (once at a time); what became of it, as logged.
  @visibleForTesting
  Future<String> run() => _running ??= _run().whenComplete(() {
    _running = null;
    _step = null;
  });

  Future<String> _run() async {
    final gen = _gen;
    final day = _today();
    final sw = Stopwatch()..start();
    // A step stops when the Reel started or video began playing; the
    // latter leaves today's run to the next look.
    String? stopAt(String step) {
      _step = step;
      if (_disposed || gen != _gen) return 'yielded at $step';
      if (playing()) return 'paused at $step (video is playing)';
      return null;
    }

    String end(String outcome, {bool done = true}) {
      if (done && gen == _gen) _doneDay = day;
      appLogger.i('[ReelWarmer] $outcome ${sw.elapsedMilliseconds}ms');
      return outcome;
    }

    appLogger.i('[ReelWarmer] begin');
    try {
      _step = 'sweep';
      await _sweep();

      if (stopAt('use') case final s?) return end(s, done: false);
      final since = _clock().subtract(usedWithin);
      final used =
          await store.usedSince(since).timeout(timeouts.store) ||
          (await forYou.pool.signals.since(since).timeout(timeouts.store)).isNotEmpty;
      if (!used) return end('skipped: the Reel was not used in ${usedWithin.inDays} days');

      // 1. Today's build (D3).
      if (stopAt('build') case final s?) return end(s, done: false);
      final build = await _build(stopAt);
      if (build.stop case final s?) return end(s, done: false);

      // 2. Today's list kept.
      if (stopAt('snapshot') case final s?) return end(s, done: false);
      final kept = await forYou.keepToday().timeout(timeouts.deck);

      // 3. The cards the Reel opens on, from the caches.
      if (stopAt('cards') case final s?) return end(s, done: false);
      final cards = await _cards();
      if (stopAt('art') case final s?) return end(s, done: false);
      final art = await _art(cards);

      return end(
        'done build=${build.outcome} list=$kept cards=${cards.isEmpty ? 'none' : cards.map((c) => c.line).join(',')} art=$art',
      );
    } catch (e) {
      appLogger.w('[ReelWarmer] failed at ${_step ?? 'start'}', error: e);
      return end('failed at ${_step ?? 'start'}');
    }
  }

  /// Step 0: the daily sweep (at most once a day; shared with the Reel's).
  Future<void> _sweep() async {
    try {
      final s = await store.sweep();
      if (s == null) return;
      appLogger.i(
        '[ReelCache] daily sweep: ${s.pools} pool, ${s.days} deck/cursor/head, '
        '${s.sources} source rows, ${s.metas} metadata rows, ${s.events} events',
      );
    } catch (e) {
      appLogger.w('[ReelCache] daily sweep failed', error: e);
    }
  }

  /// Step 1: the gather, then the call, when today's pool isn't here and
  /// this device builds it. [stopAt] is asked between the two.
  Future<({String outcome, String? stop})> _build(String? Function(String step) stopAt) async {
    if (await forYou.pool.hasToday()) return (outcome: 'had', stop: null);
    if (!await forYou.pool.shouldBuild()) return (outcome: 'not this device', stop: null);
    final sw = Stopwatch()..start();
    await forYou.prepare();
    final gatherMs = sw.elapsedMilliseconds;
    if (stopAt('build call') case final s?) return (outcome: 'gathered', stop: s);
    await forYou.buildIfDue();
    await forYou.building;
    final built = await forYou.pool.hasToday();
    return (
      outcome: '${built ? 'built' : 'none'} (gather ${gatherMs}ms, call ${sw.elapsedMilliseconds - gatherMs}ms)',
      stop: null,
    );
  }

  /// Step 3: the card the Reel will open For You on and the two after it,
  /// from the caches only.
  Future<List<_Warm>> _cards() async {
    final first = await forYou.firstCards(ReelDeck.headEntries).timeout(timeouts.deck);
    if (first.isEmpty) return const [];
    final list = await finishDeck(forYou, first, store: store, hasClip: (_) => true);
    if (list.isEmpty) return const [];
    final cursor = await ReelCursor.read(store, forYou.id, daily: forYou.daily, now: _clock());
    final at = (cursor?.seekIn(list) ?? 0).clamp(0, list.length - 1);
    final ahead = list.skip(at).take(cardsAhead).toList();
    final answers = await ClipResolver.cachedAnswers(store, [for (final c in ahead) c.title]);
    final read = cachedItem;
    return [
      for (final c in ahead)
        _Warm(c, clip: answers[c.title.groupKey], item: read == null ? null : await _cachedItem(read, c)),
    ];
  }

  Future<MediaItem?> _cachedItem(ReelCachedItem read, ReelCardData c) async {
    try {
      return await read(c.best.serverId, c.best.ratingKey).timeout(timeouts.store);
    } catch (e) {
      appLogger.d('[ReelWarmer] cached item unavailable (${e.runtimeType})');
      return null;
    }
  }

  /// Step 3, the art: the first card's, as its card view builds it.
  Future<String> _art(List<_Warm> cards) async {
    final precache = precacheArt;
    final first = cards.firstOrNull;
    final item = first?.item;
    if (precache == null || first == null) return 'none';
    if (item == null) return 'no cached item';
    if (!(artAllowed?.call() ?? true)) return 'skipped (memory)';
    try {
      await precache(first.card, item, clip: first.clip == ClipAnswer.found).timeout(timeouts.art);
      return 'warm';
    } catch (e) {
      appLogger.d('[ReelWarmer] art not warmed (${e.runtimeType})');
      return 'failed';
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  @visibleForTesting
  bool get armed => _timer != null;
}

/// One card step 3 read: its cached clip answer and item.
class _Warm {
  const _Warm(this.card, {this.clip, this.item});

  final ReelCardData card;
  final ClipAnswer? clip;
  final MediaItem? item;

  /// `clip|miss|?` then `+item` when its item was cached: one card in the
  /// done line.
  String get line =>
      '${switch (clip) {
        ClipAnswer.found => 'clip',
        ClipAnswer.none => 'miss',
        _ => '?',
      }}${item == null ? '' : '+item'}';
}
