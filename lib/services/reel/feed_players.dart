import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../../utils/app_logger.dart';

/// One card's clip in the phone feed: a player drawn into a Flutter texture,
/// so the picture slides with its page. Nothing here reports anything: these
/// are bare `video_player` controllers that know no server, timeline or
/// tracker (test/reel/no_reporting_guard_test.dart walks this file too).
abstract class FeedVideo implements Listenable {
  /// Prepared, with its first frame ready to draw.
  bool get ready;
  bool get failed;
  double get aspectRatio;
  Duration get position;
  Duration get duration;
  bool get playing;

  /// How far the clip is loaded from its start (the end of the furthest
  /// buffered range). On Android the plugin polls it once a second.
  Duration get buffered;

  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> setVolume(double volume);
  Future<void> dispose();

  /// The picture.
  Widget view();
}

/// [FeedVideo] on the `video_player` plugin (ExoPlayer on Android).
class PluginFeedVideo extends ChangeNotifier implements FeedVideo {
  PluginFeedVideo(Uri uri)
    : _c = VideoPlayerController.networkUrl(uri, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true)) {
    _c.addListener(notifyListeners);
  }

  final VideoPlayerController _c;
  bool _failed = false;

  @override
  bool get ready => _c.value.isInitialized && !_failed;
  @override
  bool get failed => _failed || _c.value.hasError;
  @override
  double get aspectRatio => _c.value.isInitialized ? _c.value.aspectRatio : 16 / 9;
  @override
  Duration get position => _c.value.position;
  @override
  Duration get duration => _c.value.duration;
  @override
  bool get playing => _c.value.isPlaying;
  @override
  Duration get buffered {
    var end = Duration.zero;
    for (final r in _c.value.buffered) {
      if (r.end > end) end = r.end;
    }
    return end;
  }

  @override
  Future<void> initialize() async {
    try {
      await _c.initialize();
      await _c.setLooping(true);
    } catch (e) {
      _failed = true;
      appLogger.d('Reel feed: clip failed to open', error: e);
      notifyListeners();
    }
  }

  @override
  Future<void> play() => _c.play();
  @override
  Future<void> pause() => _c.pause();
  @override
  Future<void> seekTo(Duration position) => _c.seekTo(position);
  @override
  Future<void> setVolume(double volume) => _c.setVolume(volume);

  @override
  Future<void> dispose() async {
    _c.removeListener(notifyListeners);
    await _c.dispose();
    super.dispose();
  }

  @override
  Widget view() => VideoPlayer(_c);
}

/// A card the feed wants a player for: its id, its clip's address, and
/// where it sits from the card on screen ([offset] 0 on screen, 1 next, 2 the
/// one after, -1 the one behind).
typedef FeedClip = ({String id, Uri uri, int offset});

/// How far the window opens around the card on screen (V2-08 step 1). Every
/// parked player keeps loading (media3's default load control ignores
/// play/pause), so the cards around it open only once the card on screen
/// has enough of its own clip loaded not to stall for them.
abstract final class FeedStaging {
  /// The next card opens once the one on screen has this much loaded ahead
  /// of where it is playing...
  static const nextLoaded = Duration(seconds: 6);

  /// ...or has played this far.
  static const nextPlayed = Duration(seconds: 3);

  /// The one after next and the one behind open once the card on screen has
  /// this much loaded ahead, and only on an unmetered link.
  static const wideLoaded = Duration(seconds: 10);

  /// A clip loaded to within this of its end counts as fully loaded.
  static const fullSlack = Duration(milliseconds: 500);
}

/// What one card's page draws (V2-02): its player once it has a picture,
/// whether it is the card on screen, and whether a tap paused it. Each page
/// listens to its own card ([ReelFeedPlayers.card]), so a player opening two
/// cards away doesn't rebuild the page you are looking at.
typedef FeedCardState = ({FeedVideo? video, bool current, bool paused});

/// The phone feed's players, the TikTok way: the card on screen plays, and
/// the cards around it (the previous one and the next two) are opened and
/// parked on their first frame, so a swipe slides a live picture in instead
/// of a still that later flashes into video. Players outside that window are
/// disposed; opening is in priority order (on screen first, then the next).
///
/// The window opens in stages by what the card on screen has loaded
/// ([FeedStaging], V2-08): the next card once it has 6 s loaded ahead or has
/// played 3 s, the one after and the one behind once it has 10 s loaded, and
/// on a metered link never more than the card on screen and the next. A
/// player already open stays while its place is allowed on the link, so a
/// dip in the buffer never closes and reopens a neighbour.
///
/// A card the swipe leaves is only paused, so it holds its frame while it is
/// still half on screen (and plays on from there if the drag comes back).
/// It goes back to its start at [settle], once the page has come to rest;
/// on a metered link that is also when it is let go if it is now behind.
class ReelFeedPlayers extends ChangeNotifier {
  ReelFeedPlayers({FeedVideo Function(Uri uri)? create, this.onLooped, this.onStarted, this.onFailed, this.onLeft})
    : _create = create ?? PluginFeedVideo.new;

  final FeedVideo Function(Uri uri) _create;

  /// The card on screen played through once (it loops on).
  final void Function(String cardId)? onLooped;

  /// The card on screen is really playing: its position has moved since it
  /// was put on screen (`isPlaying` alone flips at the play() call).
  final void Function(String cardId)? onStarted;

  /// The card on screen failed to open, or broke mid-play.
  final void Function(String cardId)? onFailed;

  /// The card stopped being the one on screen (a swipe went past the middle,
  /// or everything was let go). Its next [onStarted] is a new visit.
  final void Function(String cardId)? onLeft;

  final Map<String, _Entry> _byId = {};
  final Map<String, _CardNotifier> _cards = {};
  String? _current;

  /// The last window asked for, kept so the window can open further as the
  /// card on screen loads.
  List<FeedClip> _window = const [];
  int _memoryLevel = 0;
  bool _metered = false;

  /// How far the window has opened for this visit to the card on screen:
  /// 0 that card alone, 1 with the next, 2 all of it. It only grows, and
  /// starts again with each new card on screen.
  int _stage = 0;

  /// The card just left: it keeps its player, whatever the link, until the
  /// page settles, so it holds its frame while still half on screen.
  String? _holding;
  bool _muted = false;
  bool _paused = false;
  bool _disposed = false;

  bool get muted => _muted;

  /// Paused by a tap (the card stays paused until tapped again or left).
  bool get paused => _paused;

  String? get current => _current;

  /// The player for [cardId], once it has a picture to show.
  FeedVideo? videoFor(String cardId) {
    final v = _byId[cardId]?.video;
    return v != null && v.ready ? v : null;
  }

  /// Cards with a player now (tests and memory checks).
  Iterable<String> get held => _byId.keys;

  /// [cardId]'s page state, which changes only when that card's does.
  ValueListenable<FeedCardState> card(String cardId) =>
      _cards.putIfAbsent(cardId, () => _CardNotifier(_stateOf(cardId)));

  FeedCardState _stateOf(String cardId) {
    final current = cardId == _current;
    return (video: videoFor(cardId), current: current, paused: current && _paused);
  }

  /// Brings the window in line: [window] in priority order, the card on
  /// screen first. [current] plays (unless paused by a tap); the card it
  /// takes over from is paused where it is, and the rest wait on their
  /// first frame. The window opens in stages ([FeedStaging]); on a
  /// [metered] link it never reaches past the next card. Under memory
  /// pressure ([memoryLevel] 1) only the card on screen keeps a player, and
  /// at level 2 none does (stills only).
  void sync({required String? current, required List<FeedClip> window, int memoryLevel = 0, bool metered = false}) {
    if (_disposed) return;
    _window = window;
    _memoryLevel = memoryLevel;
    _metered = metered;
    final left = _current;
    final moved = current != _current;
    if (moved) {
      _current = current;
      _paused = false;
      _stage = 0;
      _holding = left;
    }
    _stage = math.max(_stage, _stageNow());
    _reconcile();
    if (moved) {
      if (_byId[left] case final old?) unawaited(_leave(old));
      if (left != null) onLeft?.call(left);
    }
    if (_byId[_current] case final e?) unawaited(e.opened!.then((_) => _apply(e)));
    notifyListeners();
  }

  /// The clips that may hold a player now, in priority order.
  List<FeedClip> get _kept => switch (_memoryLevel) {
    0 => [
      for (final w in _window)
        if (w.id == _holding || _reach(w.offset) <= _linkReach) w,
    ],
    1 => _window.where((w) => w.id == _current).toList(),
    _ => const <FeedClip>[],
  };

  /// How far the link lets the window reach: on a metered one, the card on
  /// screen and the next.
  int get _linkReach => _metered ? 1 : 2;

  /// The stage at which a card [offset] places from the one on screen opens.
  static int _reach(int offset) => switch (offset) {
    0 => 0,
    1 => 1,
    _ => 2,
  };

  /// How far the window may open now, by what the card on screen has loaded.
  int _stageNow() {
    // No clip on screen (a still): nothing to share with.
    if (!_window.any((w) => w.id == _current)) return 2;
    final v = _byId[_current]?.video;
    if (v == null) return 0;
    if (v.failed) return 2;
    if (!v.ready) return 0;
    final loaded = v.buffered;
    final full = v.duration > Duration.zero && loaded >= v.duration - FeedStaging.fullSlack;
    final ahead = loaded - v.position;
    if (full || ahead >= FeedStaging.wideLoaded) return 2;
    if (ahead >= FeedStaging.nextLoaded || v.position >= FeedStaging.nextPlayed) return 1;
    return 0;
  }

  /// Lets go of players whose place is no longer allowed, and opens the ones
  /// the stage now allows, in order. With [apply], each kept player is then
  /// played or parked for its place; without it (the window only opening
  /// further) nothing already open is touched.
  void _reconcile({bool apply = true}) {
    final kept = _kept;
    final keep = {for (final w in kept) w.id: w.uri};
    for (final id in _byId.keys.toList()) {
      final e = _byId[id]!;
      if (keep[id] != e.uri) unawaited(_drop(id));
    }
    final reach = math.min(_stage, _linkReach);
    Future<void>? before;
    for (final w in kept) {
      var e = _byId[w.id];
      if (e == null) {
        if (_reach(w.offset) > reach) continue;
        e = _byId[w.id] = _open(w);
      }
      final entry = e;
      // Opening in order: each waits for the one before it, and the staging
      // above holds the neighbours back until the card on screen has loaded
      // enough of its own clip.
      entry.opened ??= () async {
        await before?.catchError((Object _) {});
        if (!_isLive(entry)) return;
        await entry.video.initialize();
        if (!_isLive(entry)) return;
        await entry.video.setVolume(_muted ? 0 : 1);
        notifyListeners();
        if (entry.id == _current) _advance();
      }();
      before = entry.opened;
      if (apply) unawaited(entry.opened!.then((_) => _apply(entry)));
    }
  }

  /// The card on screen loaded or played further: open the window as far as
  /// that now allows.
  void _advance() {
    if (_disposed || _memoryLevel != 0) return;
    final stage = _stageNow();
    if (stage <= _stage) return;
    _stage = stage;
    _reconcile(apply: false);
    notifyListeners();
  }

  _Entry _open(FeedClip w) {
    final e = _Entry(w.id, w.uri, _create(w.uri));
    e.video.addListener(() => _watchLoop(e));
    return e;
  }

  bool _isLive(_Entry e) => !_disposed && identical(_byId[e.id], e);

  Future<void> _apply(_Entry e) async {
    if (!_isLive(e) || !e.video.ready) return;
    if (e.id == _current && !_paused) {
      if (!e.video.playing) await e.video.play();
    } else if (e.id != _current) {
      // Paused, not rewound: it may still be half on screen.
      await _leave(e);
    }
  }

  /// Off screen for now: stopped on the frame it was showing.
  Future<void> _leave(_Entry e) async {
    e.last = Duration.zero;
    e.started = false;
    if (e.video.ready && e.video.playing) await e.video.pause();
  }

  /// The page has come to rest: every card but the one on screen goes back
  /// to its start, so the next swipe onto it begins at the top. Nothing on
  /// screen is touched, so there is no jump to frame 0 mid-swipe. The card
  /// left behind is let go now if the link no longer allows its place.
  Future<void> settle() async {
    if (_holding != null && !_disposed) {
      _holding = null;
      _reconcile(apply: false);
      notifyListeners();
    }
    for (final e in _byId.values.toList()) {
      if (e.id == _current || !_isLive(e) || !e.video.ready) continue;
      await _leave(e);
      if (e.video.position > Duration.zero) await e.video.seekTo(Duration.zero);
    }
  }

  /// A looping clip's position jumps back to the start: one play-through.
  void _watchLoop(_Entry e) {
    if (e.id != _current) return;
    _advance();
    if (e.video.failed) {
      if (!e.failedTold) onFailed?.call(e.id);
      e.failedTold = true;
      return;
    }
    if (!e.video.playing) return;
    final pos = e.video.position;
    if (!e.started && pos > Duration.zero) {
      e.started = true;
      onStarted?.call(e.id);
    }
    if (pos + const Duration(seconds: 1) < e.last && e.last > const Duration(seconds: 3)) onLooped?.call(e.id);
    e.last = pos;
  }

  Future<void> _drop(String id) async {
    final e = _byId.remove(id);
    if (e == null) return;
    await e.opened?.catchError((Object _) {});
    await e.video.dispose();
  }

  Future<void> togglePause() async {
    final e = _byId[_current];
    if (e == null || !e.video.ready) return;
    _paused = !_paused;
    _paused ? await e.video.pause() : await e.video.play();
    notifyListeners();
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    for (final e in _byId.values) {
      if (e.video.ready) await e.video.setVolume(muted ? 0 : 1);
    }
    notifyListeners();
  }

  /// The tab went away or the screen locked: everything stops, players stay.
  Future<void> pauseAll() async {
    for (final e in _byId.values) {
      if (e.video.ready && e.video.playing) await e.video.pause();
    }
  }

  /// Real playback is about to start, or the Reel closed: free every decoder.
  Future<void> releaseAll() async {
    final left = _current;
    _current = null;
    _holding = null;
    _window = const [];
    if (left != null) onLeft?.call(left);
    for (final id in _byId.keys.toList()) {
      await _drop(id);
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    _publish();
    super.notifyListeners();
  }

  /// Hands each watched card its state; a card nobody watches and with no
  /// player is forgotten.
  void _publish() {
    _cards.removeWhere((id, n) {
      if (n.listeners == 0 && !_byId.containsKey(id) && id != _current) {
        n.dispose();
        return true;
      }
      n.value = _stateOf(id);
      return false;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(releaseAll());
    for (final n in _cards.values) {
      n.dispose();
    }
    _cards.clear();
    super.dispose();
  }
}

/// A card's [FeedCardState], counting its listeners so it can be let go.
class _CardNotifier extends ValueNotifier<FeedCardState> {
  _CardNotifier(super.value);

  int listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }
}

class _Entry {
  _Entry(this.id, this.uri, this.video);

  final String id;
  final Uri uri;
  final FeedVideo video;
  Future<void>? opened;
  Duration last = Duration.zero;

  /// Told [ReelFeedPlayers.onStarted] / [ReelFeedPlayers.onFailed] for
  /// this visit to the screen.
  bool started = false;
  bool failedTold = false;
}
