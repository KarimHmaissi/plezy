import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../../utils/app_logger.dart';
import 'feed_youtube.dart';

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

  /// Waiting for data mid-play (a stall). `video_player` reports [playing]
  /// false meanwhile, as ExoPlayer's `isPlaying` does.
  bool get buffering;

  /// Played to its end with looping off, and holding its last frame (until
  /// a seek or a play).
  bool get completed;

  /// How far the clip is loaded from its start (the end of the furthest
  /// buffered range). On Android the plugin polls it once a second.
  Duration get buffered;

  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> setVolume(double volume);

  /// Plays on from the start at the end (true) or stops on the last frame.
  Future<void> setLooping(bool looping);
  Future<void> dispose();

  /// The picture.
  Widget view();
}

/// [FeedVideo] on the `video_player` plugin (ExoPlayer on Android).
///
/// With [mixWithOthers] off (the default, V2-22) the player takes audio
/// focus: `video_player_android` 2.12.2 builds it with media3's
/// `handleAudioFocus` on, so music pauses while a card plays and a call
/// pauses the card. On, it plays over other audio and never pauses for it.
class PluginFeedVideo extends ChangeNotifier implements FeedVideo {
  PluginFeedVideo(Uri uri, {bool mixWithOthers = false})
    : _c = VideoPlayerController.networkUrl(uri, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: mixWithOthers)) {
    _c.addListener(notifyListeners);
  }

  final VideoPlayerController _c;
  bool _failed = false;
  bool _disposed = false;

  /// A player that reported an error is never ready, so its page shows the
  /// card's art instead of a frozen frame.
  @override
  bool get ready => _c.value.isInitialized && !failed;
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
  bool get buffering => _c.value.isBuffering;

  /// `video_player` 2.14.1 pauses on the `completed` event, seeks to the
  /// duration (the last frame) and sets `isCompleted` until the next play.
  @override
  bool get completed => _c.value.isCompleted;
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
      // Looping is set by the feed before each visit's first play (V2-47).
      await _c.initialize();
    } catch (e) {
      if (_disposed) return;
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
  Future<void> setLooping(bool looping) async {
    // Let go while it was opening (the feed doesn't wait for an open).
    if (_disposed) return;
    await _c.setLooping(looping);
  }

  @override
  Future<void> dispose() async {
    // The plugin's own dispose waits only for the player to be created, not
    // for the open; an open still in flight then never finishes.
    _disposed = true;
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

/// How long the card on screen may take to show it is playing (its position
/// moving) once it is asked to play, before its clip counts as failed. A
/// clip that never opens, or opens and never moves, would otherwise leave a
/// still on screen with nothing said.
abstract final class FeedWatchdog {
  static const after = Duration(seconds: 6);

  /// The same for a player page ([EmbedFeedVideo], V2-63): its open loads
  /// the page, YouTube's API script and the player's own frame before the
  /// video, so it gets longer; the controller's stuck-card watchdog waits
  /// longer still for such a card, so the feed's fallback comes first.
  static const embedAfter = Duration(seconds: 12);
}

/// Where a clip failed: still opening, opened but never moved, or broke
/// after it had played.
enum FeedFailStage { open, start, play }

/// How a clip failed: the player said so, or the watchdog ran out.
enum FeedFailCause { error, timeout }

/// How a card comes in on screen (V2-19). Clips differ in loudness (one
/// source may be mastered far louder than the next), so a card never starts
/// at full volume: it starts at [from] and rises to full over [over], in
/// [steps] steps, the way the TV dips in after a step. A card that leaves
/// the screen goes silent before it is parked, and unmuting rises the same
/// way instead of jumping.
abstract final class FeedRamp {
  /// The volume a card starts at.
  static const from = 0.3;

  /// How long it takes to reach full volume.
  static const over = Duration(milliseconds: 200);

  /// How many volume changes the rise is made of.
  static const steps = 6;
}

/// What one card's page draws (V2-02): its player once it has a picture,
/// whether it is the card on screen, whether a tap paused it, and whether
/// its clip played out and holds its last frame for Replay (V2-47). Each page
/// listens to its own card ([ReelFeedPlayers.card]), so a player opening two
/// cards away doesn't rebuild the page you are looking at.
typedef FeedCardState = ({FeedVideo? video, bool current, bool paused, bool held});

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
///
/// The screen stays on only while the card on screen is really playing
/// ([keepAwake], V2-22): a tap pause, a clip that stops by itself (it ended,
/// or the system took its audio focus), a swipe onto a still and letting
/// everything go all let the screen time out again. A card that has started
/// its visit is never played again by a re-sync: once it stops by itself
/// (a call, another app's music) it stays stopped until tapped (or a screen
/// switch re-syncs with `resume`), so it never takes the audio focus back.
///
/// A player page ([EmbedFeedVideo], the TMDB trailer rung, V2-63) opens only
/// for the card on screen: never parked ahead or kept behind, so a swipe
/// away lets it go at once and no page plays off screen. It comes on screen
/// silent on every visit ([quiet]), whatever the mute, until [unquiet]
/// (the sound control, outside the player); a mute still silences it. Its
/// watchdog waits [embedStuckAfter], and its first play state counts as
/// started (an ad before the video moves no position).
///
/// When a clip ends (V2-47, D6): it plays as many times as [plays] says,
/// looping without a gap (media3's repeat mode) until its last play, which
/// runs with looping off so it stops on its last frame. The card then holds
/// for Replay ([FeedCardState.held]) and [ended] fires; the feed moves on
/// from there with Next card. A held card stays held through a re-sync or a
/// screen switch, and plays from its start on the next visit.
class ReelFeedPlayers extends ChangeNotifier {
  ReelFeedPlayers({
    FeedVideo Function(Uri uri)? create,
    this.onLooped,
    this.onStarted,
    this.onFailed,
    this.onLeft,
    this.keepAwake,
    this.riseOver = FeedRamp.over,
    this.stuckAfter = FeedWatchdog.after,
    this.embedStuckAfter = FeedWatchdog.embedAfter,
    int? Function()? plays,
  }) : _create = create ?? PluginFeedVideo.new,
       _plays = plays ?? _forever;

  final FeedVideo Function(Uri uri) _create;

  static int? _forever() => null;

  /// How many times a card's clip plays on a visit before it holds; null
  /// loops it for good. Asked at each play-through, so a change to the
  /// clip-end pref applies to the card on screen (V2-47).
  final int? Function() _plays;

  final StreamController<String> _ended = StreamController<String>.broadcast();

  /// The card on screen played its last play and now holds (V2-47).
  Stream<String> get ended => _ended.stream;

  /// How long a card takes to rise to full volume ([FeedRamp.over]); zero
  /// sets full volume at once, with no timer (widget tests).
  final Duration riseOver;

  /// The card on screen played through once (it loops on, or holds after
  /// its last play).
  final void Function(String cardId)? onLooped;

  /// The card on screen is really playing: its position has moved since it
  /// was put on screen (`isPlaying` alone flips at the play() call).
  final void Function(String cardId)? onStarted;

  /// A card's clip failed: it errored (on screen or parked), or the card on
  /// screen didn't start playing within [stuckAfter]. Its player is let go
  /// and its address isn't opened again, so the page shows the card's art
  /// until the controller finds another clip or makes it an AI card (V2-56).
  final void Function(String cardId)? onFailed;

  /// How long the card on screen may take to start once asked to play
  /// ([FeedWatchdog]); null never times it out.
  final Duration? stuckAfter;

  /// [stuckAfter] for a player page ([FeedWatchdog.embedAfter]); a null
  /// [stuckAfter] times neither out.
  final Duration embedStuckAfter;

  /// The card stopped being the one on screen (a swipe went past the middle,
  /// or everything was let go). Its next [onStarted] is a new visit.
  final void Function(String cardId)? onLeft;

  /// Holds the screen on (true) or lets it time out (false); called only
  /// when that changes. The Reel screen hands in a `WakelockController`.
  final Future<void> Function(bool on)? keepAwake;

  /// What [keepAwake] was last told.
  bool _awake = false;

  final Map<String, _Entry> _byId = {};

  /// Clip addresses that failed here, and where. Never opened again: the
  /// controller looks the card up once more without that clip.
  final Map<Uri, FeedFailStage> _broken = {};

  /// Let go of everything ([releaseAll]) and not synced since.
  bool _letGo = false;
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

  /// The card on screen is a player page still silent this visit: the
  /// sound control shows sound off until [unquiet].
  bool get quiet => _byId[_current]?.quiet ?? false;

  /// The card on screen makes no sound now: muted, or [quiet].
  bool get soundOff => _muted || quiet;

  /// Paused by a tap (the card stays paused until tapped again or left).
  bool get paused => _paused;

  String? get current => _current;

  /// Everything was let go ([releaseAll]: the tab went away, or Watch), as
  /// opposed to a page with no card on it.
  bool get letGo => _letGo;

  /// Where [cardId]'s clip failed, while the window still offers that clip.
  FeedFailStage? failure(String cardId) {
    for (final w in _window) {
      if (w.id == cardId) return _broken[w.uri];
    }
    return null;
  }

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
    return (
      video: videoFor(cardId),
      current: current,
      paused: current && _paused,
      held: current && (_byId[cardId]?.held ?? false),
    );
  }

  /// Brings the window in line: [window] in priority order, the card on
  /// screen first. [current] plays (unless paused by a tap); the card it
  /// takes over from is paused where it is, and the rest wait on their
  /// first frame. The window opens in stages ([FeedStaging]); on a
  /// [metered] link it never reaches past the next card. Under memory
  /// pressure ([memoryLevel] 1) only the card on screen keeps a player, and
  /// at level 2 none does (stills only).
  ///
  /// A card on screen that stopped by itself is left stopped by a re-sync
  /// (V2-22), unless [resume] asks for it again (a screen switch, V2-65).
  void sync({
    required String? current,
    required List<FeedClip> window,
    int memoryLevel = 0,
    bool metered = false,
    bool resume = false,
  }) {
    if (_disposed) return;
    _letGo = false;
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
    if (_byId[_current] case final e?) unawaited(e.opened!.then((_) => _apply(e, resume: resume)));
    _arm();
    unawaited(_syncAwake());
    notifyListeners();
  }

  /// Starts the card on screen's watchdog ([stuckAfter]) if it hasn't shown
  /// it is playing this visit. A tap pause stops it; leaving the card, or
  /// its position moving, ends it.
  void _arm() {
    final e = _byId[_current];
    if (stuckAfter == null || e == null || _paused || e.started || e.held || e.watchdog != null) return;
    final after = e.embed ? embedStuckAfter : stuckAfter!;
    e.watchdog = Timer(after, () {
      e.watchdog = null;
      if (!_isLive(e) || e.id != _current || _paused || e.started || e.held) return;
      // Asked to play and stopped by the system before it moved (a call
      // took the audio focus): not broken, and left stopped (V2-22). A
      // player page that never played is still opening: it counts.
      if (!e.embed && e.open && e.voiced && !e.video.playing && !e.video.buffering) return;
      _fail(e, _stageOf(e), FeedFailCause.timeout);
    });
  }

  /// How far [e] got: still opening, open but never moved this visit, or
  /// moved and then broke.
  static FeedFailStage _stageOf(_Entry e) => e.started
      ? FeedFailStage.play
      : e.open
      ? FeedFailStage.start
      : FeedFailStage.open;

  /// [e]'s clip failed: logged, its player let go (the page shows the card's
  /// art), its address kept from opening again, and the controller told so
  /// it can look for another clip (V2-56). The window then opens as for a
  /// card with no clip.
  void _fail(_Entry e, FeedFailStage stage, FeedFailCause cause) {
    if (!_isLive(e) || _broken.containsKey(e.uri)) return;
    _broken[e.uri] = stage;
    final where = e.id == _current ? 'screen' : 'parked';
    appLogger.i(
      '[ReelFeed] clip failed stage=${stage.name} cause=${cause.name} on=$where${e.embed ? ' kind=embed' : ''}',
    );
    unawaited(_drop(e.id));
    if (_memoryLevel == 0) _stage = math.max(_stage, _stageNow());
    _reconcile(apply: false);
    unawaited(_syncAwake());
    notifyListeners();
    onFailed?.call(e.id);
  }

  /// Tells [keepAwake] whether the card on screen is really playing. A stall
  /// mid-play still counts: letting the screen go for it would dim a screen
  /// left untouched past its timeout.
  Future<void> _syncAwake() async {
    final e = _byId[_current];
    final on =
        !_disposed &&
        !_paused &&
        e != null &&
        e.video.ready &&
        (e.video.playing || (e.voiced && e.video.buffering && !e.video.completed));
    if (on == _awake) return;
    _awake = on;
    await keepAwake?.call(on);
  }

  /// The clips that may hold a player now, in priority order.
  List<FeedClip> get _kept => switch (_memoryLevel) {
    0 => [
      for (final w in _window)
        if (!_broken.containsKey(w.uri) &&
            (!isEmbed(w.uri) || w.offset == 0) &&
            (w.id == _holding || _reach(w.offset) <= _linkReach))
          w,
    ],
    1 => _window.where((w) => w.id == _current && !_broken.containsKey(w.uri)).toList(),
    _ => const <FeedClip>[],
  };

  /// A clip played in a player page (V2-63): only the card on screen opens
  /// one.
  static bool isEmbed(Uri uri) => ReelYouTube.idOf(uri) != null;

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
    // No clip on screen (a still, or one that failed): nothing to share with.
    if (!_window.any((w) => w.id == _current && !_broken.containsKey(w.uri))) return 2;
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
      // enough of its own clip. A player let go mid-open counts as done
      // ([_Entry.dropped]): its open may never finish once disposed, and the
      // ones after it must not wait on it.
      entry.opened ??= Future.any([
        () async {
          await before?.catchError((Object _) {});
          if (!_isLive(entry)) return;
          await entry.video.initialize();
          if (!_isLive(entry)) return;
          // Failed to open: let go, and the ones after it open.
          if (entry.video.failed || !entry.video.ready) {
            return _fail(entry, FeedFailStage.open, FeedFailCause.error);
          }
          entry.open = true;
          // Parked (paused, so silent) at the volume a card comes in at
          // ([FeedRamp]), so a swipe onto it plays without first waiting on
          // a volume change. A player page starts silent.
          await _volume(entry, _muted || entry.quiet ? 0 : FeedRamp.from);
          // Its looping for a first play, sent while parked so a swipe onto
          // it has nothing to wait on (V2-47). Not awaited: the plugin's
          // calls reach the player in the order they are made.
          if (!_isLive(entry)) return;
          unawaited(_loop(entry));
          notifyListeners();
          if (entry.id == _current) _advance();
        }(),
        entry.dropped.future,
      ]);
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
    if (e.embed) {
      e.quiet = true;
      appLogger.i('[ReelFeed] embed open card on screen');
    }
    e.video.addListener(() {
      _watchLoop(e);
      if (e.id == _current) unawaited(_syncAwake());
    });
    return e;
  }

  bool _isLive(_Entry e) => !_disposed && identical(_byId[e.id], e);

  Future<void> _apply(_Entry e, {bool resume = false}) async {
    if (!_isLive(e) || !e.video.ready) return;
    if (e.id == _current && !_paused) {
      // Played out this visit: it holds for Replay, even through a screen
      // switch.
      if (e.held) return;
      if (e.video.playing) return;
      // A start already on its way (the open and the sync both apply).
      if (e.starting case final s?) return s;
      // Started this visit and stopped by itself since (the system took the
      // audio focus): left as it is, or it would take the focus back.
      if (e.voiced && !resume) return;
      await (e.starting = _start(e).whenComplete(() => e.starting = null));
    } else if (e.id != _current) {
      // Paused, not rewound: it may still be half on screen.
      await _leave(e);
    }
  }

  /// Plays the card on screen. The first play of a visit comes in quietly
  /// and rises to full (V2-19).
  Future<void> _start(_Entry e) async {
    final fresh = !e.voiced;
    final rise = fresh && !_muted && !e.quiet;
    e.voiced = true;
    if (fresh) {
      // A new visit counts its plays afresh, and a card left holding from
      // an earlier one starts from the top.
      e.plays = 0;
      if (e.held) {
        e.held = false;
        await e.video.seekTo(Duration.zero);
        if (!_isLive(e)) return;
      }
      await _loop(e);
      if (!_isLive(e)) return;
    }
    if (rise) await _volume(e, FeedRamp.from);
    if (!_isLive(e)) return;
    await e.video.play();
    unawaited(_syncAwake());
    if (rise && _isLive(e) && e.id == _current && !_muted) _rise(e);
  }

  /// Off screen for now: silenced, then stopped on the frame it was showing.
  Future<void> _leave(_Entry e) async {
    // A player page's next visit starts silent again.
    if (e.embed) e.quiet = true;
    e.last = Duration.zero;
    e.started = false;
    e.voiced = false;
    e.plays = 0;
    e.held = false;
    e.ended = false;
    e.ramp?.cancel();
    e.watchdog?.cancel();
    e.watchdog = null;
    // A player page asked to play may still be loading its player or
    // buffering, and would start once it can: it is always told to stop.
    if (!e.video.ready || (!e.video.playing && !e.embed)) return;
    await _volume(e, 0);
    await e.video.pause();
  }

  /// Loops [e] while it has more than this play left ([plays]), so its last
  /// play stops on the final frame; skips a call that would change nothing.
  Future<void> _loop(_Entry e) async {
    final plays = _plays();
    final on = plays == null || e.plays + 1 < plays;
    if (e.looping == on) return;
    e.looping = on;
    await e.video.setLooping(on);
  }

  /// Sets [e]'s volume, skipping a call that would change nothing.
  Future<void> _volume(_Entry e, double volume) async {
    if (e.volume == volume) return;
    e.volume = volume;
    await e.video.setVolume(volume);
  }

  /// Raises the card on screen from where it is to full volume over
  /// [riseOver]. A leave, a mute or a let-go stops it.
  void _rise(_Entry e) {
    e.ramp?.cancel();
    if (riseOver <= Duration.zero) {
      unawaited(_volume(e, 1.0));
      return;
    }
    final from = e.volume ?? FeedRamp.from;
    var i = 0;
    e.ramp = Timer.periodic(riseOver ~/ FeedRamp.steps, (t) {
      if (!_isLive(e) || _muted || e.quiet || e.id != _current) {
        t.cancel();
        return;
      }
      i++;
      final done = i >= FeedRamp.steps;
      unawaited(_volume(e, done ? 1.0 : from + (1 - from) * i / FeedRamp.steps));
      if (done) t.cancel();
    });
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
      // A swipe may have brought it on screen while it was being parked.
      if (e.id == _current || !_isLive(e)) continue;
      if (e.video.position > Duration.zero) await e.video.seekTo(Duration.zero);
    }
  }

  /// One play-through: a looping clip's position jumps back to the start,
  /// or a clip on its last play stops at its end (V2-47).
  void _watchLoop(_Entry e) {
    // A parked card that breaks is let go too, so it never comes on screen
    // as a frozen frame, and its card is looked up again early.
    if (e.video.failed) {
      if (!_isLive(e)) return;
      // After this notification: the player is let go, and a notifier
      // can't be disposed while it is notifying.
      final stage = _stageOf(e);
      scheduleMicrotask(() => _fail(e, stage, FeedFailCause.error));
      return;
    }
    if (e.id != _current) return;
    _advance();
    // Stopped at its end (the plugin pauses on it): told once per end.
    if (e.video.completed && !e.video.playing) {
      if (e.started && !e.ended && _isLive(e)) {
        e.ended = true;
        _completed(e);
      }
      return;
    }
    e.ended = false;
    if (!e.video.playing) return;
    final pos = e.video.position;
    // A player page counts from its first play state: an ad before the
    // video plays at position 0.
    final up = pos > Duration.zero || (e.video is EmbedFeedVideo && (e.video as EmbedFeedVideo).pictureUp);
    if (!e.started && up) {
      e.started = true;
      e.watchdog?.cancel();
      e.watchdog = null;
      onStarted?.call(e.id);
    }
    if (pos + const Duration(seconds: 1) < e.last && e.last > const Duration(seconds: 3)) {
      e.plays++;
      onLooped?.call(e.id);
      // The next play is the last: it stops on the final frame.
      unawaited(_loop(e));
    }
    e.last = pos;
  }

  /// The card on screen stopped at its end. With plays left (the pref went
  /// to Loop, or to more plays, mid-clip) it plays on from the start;
  /// otherwise it holds its last frame for Replay.
  void _completed(_Entry e) {
    e.plays++;
    e.last = Duration.zero;
    onLooped?.call(e.id);
    final plays = _plays();
    if (plays == null || e.plays < plays) {
      unawaited(() async {
        await _loop(e);
        if (_isLive(e) && e.id == _current && !_paused) await e.video.play();
      }());
      return;
    }
    e.held = true;
    unawaited(_syncAwake());
    notifyListeners();
    if (!_ended.isClosed) _ended.add(e.id);
  }

  /// Replay on a held card (V2-47): its plays start again from the top.
  Future<void> replay() async {
    final e = _byId[_current];
    if (e == null || !e.video.ready || !_isLive(e)) return;
    e.held = false;
    e.plays = 0;
    e.last = Duration.zero;
    _paused = false;
    await _loop(e);
    if (!_isLive(e)) return;
    await e.video.seekTo(Duration.zero);
    if (!_isLive(e) || e.id != _current) return;
    await e.video.play();
    unawaited(_syncAwake());
    notifyListeners();
  }

  /// Lets [id]'s player go at once, without waiting for its open (V2-06): a
  /// slow open of a neighbour must not hold up Watch or a memory trim.
  Future<void> _drop(String id) async {
    final e = _byId.remove(id);
    if (e == null) return;
    e.ramp?.cancel();
    e.watchdog?.cancel();
    e.watchdog = null;
    if (!e.dropped.isCompleted) e.dropped.complete();
    try {
      await e.video.dispose();
    } catch (err) {
      appLogger.d('Reel feed: clip player failed to dispose', error: err);
    }
  }

  /// A tap: pauses or plays the card on screen; on a held card, replays.
  Future<void> togglePause() async {
    final e = _byId[_current];
    if (e == null || !e.video.ready) return;
    if (e.held) return replay();
    _paused = !_paused;
    if (_paused) {
      e.watchdog?.cancel();
      e.watchdog = null;
    } else {
      _arm();
    }
    unawaited(_syncAwake());
    _paused ? await e.video.pause() : await e.video.play();
    unawaited(_syncAwake());
    notifyListeners();
  }

  /// Mute silences every player at once; unmute brings only the card on
  /// screen back, rising from [FeedRamp.from] rather than jumping to full
  /// (V2-19). Parked cards stay silent until they come on screen.
  Future<void> setMuted(bool muted) async {
    if (muted == _muted) return;
    _muted = muted;
    for (final e in _byId.values.toList()) {
      e.ramp?.cancel();
      if (!e.video.ready || !_isLive(e)) continue;
      if (muted) {
        await _volume(e, 0);
      } else if (e.id == _current && e.voiced && !e.quiet) {
        await _volume(e, FeedRamp.from);
        if (_isLive(e) && e.id == _current && !_muted) _rise(e);
      }
    }
    notifyListeners();
  }

  /// The sound control on a [quiet] card (V2-63): this visit has sound,
  /// rising from [FeedRamp.from] unless the feed is muted (the caller then
  /// lifts the mute, which rises it).
  Future<void> unquiet() async {
    final e = _byId[_current];
    if (e == null || !e.quiet) return;
    e.quiet = false;
    appLogger.i('[ReelFeed] embed sound on');
    if (!_muted && e.video.ready && e.voiced && _isLive(e)) {
      await _volume(e, FeedRamp.from);
      if (_isLive(e) && e.id == _current && !_muted && !e.quiet) _rise(e);
    }
    notifyListeners();
  }

  /// The tab went away or the screen locked: everything stops, players stay.
  Future<void> pauseAll() async {
    for (final e in _byId.values) {
      // Played afresh when the feed comes back (a new visit); timed again
      // from then.
      e.voiced = false;
      e.watchdog?.cancel();
      e.watchdog = null;
      // A player page is always told (one still buffering would play on
      // behind the app otherwise).
      if (e.video.ready && (e.video.playing || e.embed)) await e.video.pause();
    }
    await _syncAwake();
  }

  /// Real playback is about to start, or the Reel closed: free every decoder,
  /// all at once (V2-06). The pages stop drawing the players before they go.
  Future<void> releaseAll() async {
    final left = _current;
    _current = null;
    _holding = null;
    _window = const [];
    _letGo = true;
    if (left != null) onLeft?.call(left);
    final drops = [for (final id in _byId.keys.toList()) _drop(id), _syncAwake()];
    notifyListeners();
    // The screen is let go before real playback takes it (two
    // WakelockControllers, one platform flag).
    await Future.wait(drops);
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
    unawaited(_ended.close());
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

  /// A player page (V2-63) rather than a native player.
  bool get embed => video is EmbedFeedVideo;

  /// A player page silent this visit until the sound control is tapped.
  bool quiet = false;
  Future<void>? opened;

  /// Completes when the player is let go, so [opened] does too.
  final Completer<void> dropped = Completer<void>();
  Duration last = Duration.zero;

  /// Told [ReelFeedPlayers.onStarted] for this visit to the screen.
  bool started = false;

  /// Times the card on screen from its ask to play ([FeedWatchdog]).
  Timer? watchdog;

  /// Its open finished with a picture.
  bool open = false;

  /// Has had its first play of this visit, so its volume rise has begun
  /// (or is owed on unmute).
  bool voiced = false;

  /// The volume last set on the player; null before the first.
  double? volume;

  /// Looping as last set on the player; null before the first.
  bool? looping;

  /// Play-throughs this visit, and whether the last one ended and the card
  /// now holds its final frame (V2-47).
  int plays = 0;
  bool held = false;

  /// The end the player is stopped at was already counted.
  bool ended = false;

  /// A play of the card on screen on its way.
  Future<void>? starting;

  /// The rise to full volume in progress ([FeedRamp]).
  Timer? ramp;
}
