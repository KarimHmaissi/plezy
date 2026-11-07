import 'dart:async';

import '../../utils/app_logger.dart';
import 'clip_resolver.dart';

/// What a prefetch task does for its card, in the order a card's stages
/// run: its clip first, then its art and text (plan V2-11), then, for the
/// next two cards, its art decoded into the image cache (plan V2-13), then,
/// on the TV, its clip's first seconds buffered on the clip core (the
/// native preload, plans V2-09 and V2-11 Wave B).
enum ReelPrefetchStage { resolve, metadata, art, preload }

/// One piece of work for one card near the one on screen.
class ReelPrefetchTask {
  ReelPrefetchTask({
    required this.cardId,
    required int offset,
    required this.stage,
    required this.lane,
    required this._run,
  }) : assert(ReelPrefetcher.order.contains(offset)),
       _offset = offset;

  final String cardId;

  /// Where the card sits from the one on screen, in the direction of travel:
  /// 0 is the card on screen, 1 the next, -1 the one behind, 2 the one after
  /// next; [ReelPrefetcher.deckHead] for a neighbouring deck's head.
  int get offset => _offset;
  int _offset;
  final ReelPrefetchStage stage;

  /// Who answers it: a server id, or [ReelPrefetcher.animeThemesLane]. One
  /// lookahead task runs at a time per lane.
  final String lane;
  final Future<void> Function() _run;
  final Completer<bool> _done = Completer<bool>();

  String get key => ReelPrefetcher.keyOf(cardId, stage);

  /// Its place in the queue: by distance ([ReelPrefetcher.order]), then by
  /// stage.
  int get rank => ReelPrefetcher.order.indexOf(offset) * ReelPrefetchStage.values.length + stage.index;

  void _finish(bool ran) {
    if (!_done.isCompleted) _done.complete(ran);
  }
}

/// The Reel's one prefetch queue (plan V2-11): the cards around the one on
/// screen, nearest first (0, +1, -1, +2), each card's clip before its art
/// and text.
///
/// - **Lanes.** One lookahead task at a time per server, and AnimeThemes in
///   a lane of its own, so an opening never waits behind a slow server's
///   extras. The card on screen (offset 0) never queues: its tasks start at
///   once, so its clip never waits behind cards passed over, and its art and
///   text never wait on its clip (V2-03). The resolver and the metadata
///   reader each keep one request in flight per server underneath.
/// - **Generations.** Each card change hands over its window under the
///   controller's generation counter. Queued tasks of an older window that
///   the new one doesn't ask for are dropped (their [done] says false); a
///   task already running finishes, since an HTTP read can't be called back,
///   and its answer is kept for when the card comes round.
/// - **Hold.** While the card on screen's clip is opening, only its own
///   tasks run ([hold]), until its first frame ([release]) or [holdCap].
/// - **Deck heads.** The heads of the neighbouring decks come last, after
///   +2 ([deckHead]), and only once the card on screen has shown its first
///   frame or turned out not to play ([release]); [holdCap] never lets them
///   go (plan V2-09: neighbour preloads start after the first frame).
/// - **Clear.** On Watch, suspend, a deck change or memory pressure the
///   queue empties ([clear]).
class ReelPrefetcher {
  ReelPrefetcher({this.holdCap = const Duration(seconds: 4), this.taskCap = const Duration(seconds: 60)});

  /// The cards of the deck on screen worth fetching, by distance from the
  /// card on screen.
  static const List<int> offsets = [0, 1, -1, 2];

  /// A neighbouring deck's head (the card → or ← lands on): queued after
  /// +2 (plans V2-09 and V2-11 Wave B).
  static const int deckHead = 3;

  /// The queue's order.
  static const List<int> order = [...offsets, deckHead];

  /// The cards worth fetching on a metered or offline link, or under memory
  /// pressure: the one on screen and the next.
  static const List<int> leanOffsets = [0, 1];

  /// The lane of AnimeThemes lookups (not a server id: those are opaque
  /// machine ids).
  static const String animeThemesLane = '~animethemes';

  /// The longest a loading clip holds the lookahead: a clip that never shows
  /// a frame mustn't starve the cards after it.
  final Duration holdCap;

  /// The longest a task holds its lane: one that never comes back (a read
  /// on a connection that died in a long standby) frees the lane after this,
  /// so the cards behind it are never stuck waiting on it. The tasks bound
  /// their own waits well inside it; this is the backstop.
  final Duration taskCap;

  static String keyOf(String cardId, ReelPrefetchStage stage) => '$cardId/${stage.name}';

  /// The lane of art precaches for [serverId]'s images. Kept apart from the
  /// server's own lane because an art task waits for its card's clip and
  /// text first, and a task waiting on another lane while holding this one
  /// could stall the queue; the art downloads still go one at a time per
  /// server.
  static String artLaneOf(String serverId) => '$serverId~art';

  /// The lane of the native preload for one rank of the clip core (V2-09):
  /// each rank in a lane of its own, so a preload waiting on its card's clip
  /// never holds up another rank's.
  static String preloadLaneOf(String rank) => '~preload/$rank';

  /// The lane a card's clip lookup starts in: AnimeThemes for an anime
  /// show, else the server the ladder asks first (an HD copy before 4K).
  static String laneFor(ReelTitle t) {
    if (t.anime && t.isShow) return animeThemesLane;
    final copies = [...t.copies]..sort((a, b) => (a.is4k ? 1 : 0).compareTo(b.is4k ? 1 : 0));
    return copies.firstOrNull?.serverId ?? '';
  }

  final List<ReelPrefetchTask> _queued = [];
  final Map<String, ReelPrefetchTask> _running = {};
  final Map<String, int> _busy = {};
  int _generation = -1;
  bool _held = false;

  /// The card on screen has shown its first frame (or won't play) since the
  /// last [hold]: the deck heads may go.
  bool _framed = true;
  Timer? _holdTimer;
  bool _disposed = false;

  /// Lookahead waits while true (the card on screen's clip is opening).
  bool get held => _held;

  /// Holds the lookahead from now: a new card's clip is opening. Lifts on
  /// [release], or by itself after [holdCap] (except for the deck heads,
  /// which wait for [release]).
  void hold() {
    if (_disposed) return;
    _holdTimer?.cancel();
    _held = true;
    _framed = false;
    _holdTimer = Timer(holdCap, _capped);
  }

  /// The hold ran out with no first frame: the cards of this deck go on.
  void _capped() {
    _holdTimer = null;
    if (!_held) return;
    _held = false;
    _wake(_liftWaiters);
    _pump();
  }

  /// Whether the deck heads are waiting for the card on screen's first
  /// frame.
  bool get headsHeld => !_framed;

  /// The card on screen's clip showed its first frame (or won't play): the
  /// lookahead goes on, deck heads included.
  void release() {
    _holdTimer?.cancel();
    _holdTimer = null;
    if (!_held && _framed) return;
    _held = false;
    _framed = true;
    _wake(_liftWaiters);
    _wake(_framedWaiters);
    _pump();
  }

  /// Completes once the lookahead may go on: at once when it isn't [held],
  /// else on [release] or [holdCap]. With [heads], on [release] only (the
  /// deck heads' rule). A task that started before a new card's clip began
  /// opening (it was waiting on its card's clip, say) waits here before it
  /// hands the clip core anything, so the open on screen never shares it
  /// with a preload (V2-09).
  Future<void> whenLifted({bool heads = false}) {
    if (_disposed || (heads ? _framed : !_held)) return Future.value();
    final waiter = Completer<void>();
    (heads ? _framedWaiters : _liftWaiters).add(waiter);
    return waiter.future;
  }

  final List<Completer<void>> _liftWaiters = [];
  final List<Completer<void>> _framedWaiters = [];

  static void _wake(List<Completer<void>> waiters) {
    final all = [...waiters];
    waiters.clear();
    for (final w in all) {
      if (!w.isCompleted) w.complete();
    }
  }

  /// Queued tasks, in the order they would run (for the debug overlay and
  /// tests).
  List<ReelPrefetchTask> get queued => List.unmodifiable(_queued);

  /// Tasks running now.
  Iterable<ReelPrefetchTask> get running => _running.values;

  /// Hands over the window for [generation]. A window from an older
  /// generation than the last is ignored. A task already queued or running
  /// under the same [ReelPrefetchTask.key] is kept rather than doubled.
  void schedule(int generation, List<ReelPrefetchTask> tasks) {
    if (_disposed || generation < _generation) {
      for (final t in tasks) {
        t._finish(false);
      }
      return;
    }
    _generation = generation;
    final previous = {for (final t in _queued) t.key: t};
    final next = <ReelPrefetchTask>[];
    final keys = <String>{};
    for (final t in tasks) {
      if (!keys.add(t.key) || _running.containsKey(t.key)) {
        t._finish(false);
        continue;
      }
      final kept = previous.remove(t.key);
      if (kept == null) {
        next.add(t);
      } else {
        // The same work at its new distance; whoever waits on it still does.
        kept._offset = t.offset;
        t._finish(false);
        next.add(kept);
      }
    }
    for (final dropped in previous.values) {
      dropped._finish(false);
    }
    if (previous.isNotEmpty) appLogger.d('[ReelPrefetch] dropped ${previous.length} queued');
    _queued
      ..clear()
      ..addAll(next);
    _sort();
    _pump();
  }

  /// Drops everything queued; a task already running finishes.
  void clear() {
    if (_queued.isEmpty) return;
    appLogger.d('[ReelPrefetch] cleared ${_queued.length} queued');
    for (final t in _queued) {
      t._finish(false);
    }
    _queued.clear();
  }

  /// Completes when the task under [key] has run (true) or was dropped
  /// (false); at once with true when there is none.
  Future<bool> done(String key) {
    final t = _running[key] ?? _queued.where((t) => t.key == key).firstOrNull;
    return t?._done.future ?? Future.value(true);
  }

  void dispose() {
    _disposed = true;
    _holdTimer?.cancel();
    _holdTimer = null;
    _wake(_liftWaiters);
    _wake(_framedWaiters);
    clear();
  }

  void _sort() {
    final order = {for (final (i, t) in _queued.indexed) t: i};
    _queued.sort((a, b) {
      final r = a.rank.compareTo(b.rank);
      return r != 0 ? r : order[a]!.compareTo(order[b]!);
    });
  }

  /// Starts every task that may run now: the card on screen's at once, the
  /// rest nearest first, one per free lane, unless [held].
  void _pump() {
    if (_disposed) return;
    for (final t in [..._queued]) {
      final onScreen = t.offset == 0;
      if (!onScreen && (_held || (_busy[t.lane] ?? 0) > 0)) continue;
      if (t.offset == deckHead && !_framed) continue;
      _queued.remove(t);
      _start(t);
    }
  }

  void _start(ReelPrefetchTask t) {
    _running[t.key] = t;
    _busy.update(t.lane, (n) => n + 1, ifAbsent: () => 1);
    unawaited(
      Future<void>.sync(t._run)
          .timeout(taskCap)
          .catchError((Object e) => appLogger.d('[ReelPrefetch] ${t.stage.name} failed', error: e))
          .whenComplete(() {
            if (identical(_running[t.key], t)) _running.remove(t.key);
            final n = (_busy[t.lane] ?? 1) - 1;
            if (n <= 0) {
              _busy.remove(t.lane);
            } else {
              _busy[t.lane] = n;
            }
            t._finish(true);
            _pump();
          }),
    );
  }
}
