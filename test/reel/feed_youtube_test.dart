import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/feed_players.dart';
import 'package:plezy/services/reel/feed_youtube.dart';

/// The phone's TMDB trailer rung in the feed (V2-63): the IFrame player page
/// behind [FeedVideo], and how the feed treats such a page.

/// The page without a WebView: records the script calls, and lets the test
/// post what the page's script would.
class _FakeBridge implements YouTubeBridge {
  _FakeBridge({this.loads = true});

  final bool loads;
  final Completer<void> gate = Completer<void>();
  final List<String> scripts = [];
  final StreamController<String> _messages = StreamController<String>.broadcast(sync: true);
  String? html;
  String? baseUrl;
  bool released = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> load(String html, {required String baseUrl}) async {
    this.html = html;
    this.baseUrl = baseUrl;
    if (!loads) return gate.future;
  }

  @override
  Future<void> run(String script) async => scripts.add(script);

  void post(Map<String, Object?> m) => _messages.add(jsonEncode(m));

  void postRaw(String raw) => _messages.add(raw);

  @override
  Widget view() => const SizedBox();

  int releases = 0;

  @override
  Future<void> release() async {
    released = true;
    releases++;
    if (!_messages.isClosed) await _messages.close();
  }
}

/// A page whose script calls never come back.
class _StuckBridge extends _FakeBridge {
  @override
  Future<void> run(String script) => Completer<void>().future;
}

/// A player page for the feed tests: opens at once, plays when asked.
class _FakeEmbed extends ChangeNotifier implements EmbedFeedVideo {
  _FakeEmbed(this.uri);

  final Uri uri;
  final calls = <String>[];
  bool _ready = false;
  bool _playing = false;
  bool disposed = false;
  bool up = false;
  bool broken = false;
  Duration _position = Duration.zero;

  @override
  bool get ready => _ready;
  @override
  bool get failed => broken;
  @override
  bool get pictureUp => up;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Duration get position => _position;
  @override
  Duration get duration => const Duration(seconds: 120);
  @override
  bool get playing => _playing;
  @override
  bool get buffering => false;
  @override
  bool get completed => false;
  @override
  Duration get buffered => Duration.zero;

  @override
  Future<void> initialize() async {
    calls.add('init');
    _ready = true;
  }

  @override
  Future<void> play() async => calls.add('play');

  /// The page reports its first play state (an ad, or the video at 0).
  void startsPlaying() {
    _playing = true;
    up = true;
    notifyListeners();
  }

  void breaks() {
    broken = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing = false;
  }

  @override
  Future<void> seekTo(Duration position) async => _position = position;
  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');
  @override
  Future<void> setLooping(bool looping) async {}

  @override
  Future<void> dispose() async {
    disposed = true;
    calls.add('dispose');
    super.dispose();
  }

  @override
  Widget view() => const SizedBox();
}

/// A native player for the cards around it.
class _Native extends ChangeNotifier implements FeedVideo {
  final calls = <String>[];
  bool _ready = false;
  @override
  bool get ready => _ready;
  @override
  bool get failed => false;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => const Duration(seconds: 60);
  @override
  bool get playing => false;
  @override
  bool get buffering => false;
  @override
  bool get completed => false;
  @override
  Duration get buffered => duration;
  @override
  Future<void> initialize() async => _ready = true;
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');
  @override
  Future<void> setLooping(bool looping) async {}
  @override
  Future<void> dispose() async => super.dispose();
  @override
  Widget view() => const SizedBox();
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final Uri _yt = Uri.parse(ReelYouTube.watchUri('AbCdEfGhIj1'));
FeedClip _embed(String id, int offset) =>
    (id: id, uri: _yt.replace(queryParameters: {'v': 'Card${id}00000'}), offset: offset);
FeedClip _native(String id, int offset) => (id: id, uri: Uri.parse('https://cdn.example/$id.mp4'), offset: offset);

List<double> _volumes(List<String> calls) => [
  for (final c in calls)
    if (c.startsWith('volume ')) double.parse(c.substring(7)),
];

void main() {
  group('ReelYouTube', () {
    test('a watch URL round-trips its id; anything else is not a YouTube clip', () {
      expect(ReelYouTube.idOf(Uri.parse(ReelYouTube.watchUri('AbCdEfGhIj1'))), 'AbCdEfGhIj1');
      expect(ReelYouTube.idOf(Uri.parse('https://cdn.example/clip.mp4')), isNull);
      expect(ReelYouTube.idOf(Uri.parse('https://www.youtube.com/watch?v=bad%22id')), isNull);
      expect(ReelYouTube.idOf(Uri.parse('http://www.youtube.com/watch?v=AbCdEfGhIj1')), isNull);
    });

    test('the origin is https:// and the app id (RMF client identity)', () {
      expect(ReelYouTube.originFor('com.example.reelapp'), 'https://com.example.reelapp');
      expect(ReelYouTube.originFor('not an id'), isNull);
      expect(ReelYouTube.originFor('single'), isNull);
    });

    test('the page loads the IFrame API, mutes in onReady and sets the documented parameters', () {
      final html = ReelYouTube.html(id: 'AbCdEfGhIj1', origin: 'https://com.example.reelapp');
      expect(html, contains('https://www.youtube.com/iframe_api'));
      expect(html, contains('onYouTubeIframeAPIReady'));
      expect(html, contains('videoId:"AbCdEfGhIj1"'));
      expect(html, contains('"origin":"https://com.example.reelapp"'));
      expect(html, contains('"autoplay":0'));
      expect(html, contains('"controls":0'));
      expect(html, contains('"enablejsapi":1'));
      expect(html, contains('onReady:function(){ready=true;player.mute();'));
      expect(html, contains('onAutoplayBlocked'));
    });
  });

  group('YouTubeFeedVideo', () {
    late _FakeBridge bridge;
    late YouTubeFeedVideo v;

    setUp(() {
      bridge = _FakeBridge();
      v = YouTubeFeedVideo('AbCdEfGhIj1', origin: () async => 'https://com.example.reelapp', bridge: bridge);
    });

    test('ready once the page has loaded at the app\'s origin; the picture is up only once it plays', () async {
      expect(v.ready, isFalse);
      await v.initialize();
      expect(bridge.baseUrl, 'https://com.example.reelapp');
      expect(v.ready, isTrue);
      expect(v.pictureUp, isFalse);
      bridge.post({'e': 'ready'});
      bridge.post({'e': 'state', 's': YouTubeState.buffering});
      expect(v.buffering, isTrue);
      expect(v.pictureUp, isFalse);
      bridge.post({'e': 'state', 's': YouTubeState.playing});
      expect(v.playing, isTrue);
      expect(v.pictureUp, isTrue);
      bridge.post({'e': 'tick', 't': 12.5, 'd': 120, 'l': 0.5, 's': YouTubeState.playing});
      expect(v.position, const Duration(milliseconds: 12500));
      expect(v.duration, const Duration(seconds: 120));
      expect(v.buffered, const Duration(seconds: 60));
      bridge.post({'e': 'state', 's': YouTubeState.paused});
      expect(v.pictureUp, isTrue, reason: 'a pause keeps the picture up');
      bridge.post({'e': 'state', 's': YouTubeState.ended});
      expect(v.completed, isTrue);
    });

    test('a page that never loads fails at the open timeout', () {
      fakeAsync((async) {
        final slow = _FakeBridge(loads: false);
        final s = YouTubeFeedVideo(
          'AbCdEfGhIj1',
          origin: () async => 'https://com.example.reelapp',
          bridge: slow,
          openTimeout: const Duration(seconds: 2),
        );
        unawaited(s.initialize());
        async.elapse(const Duration(seconds: 1));
        expect(s.failed, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(s.failed, isTrue);
        expect(s.ready, isFalse);
      });
    });

    test('no app id fails the open', () async {
      final s = YouTubeFeedVideo('AbCdEfGhIj1', origin: () async => null, bridge: bridge);
      await s.initialize();
      expect(s.failed, isTrue);
      expect(bridge.html, isNull);
    });

    for (final (name, message) in [
      ('embedding disabled (101)', {'e': 'error', 'c': 101}),
      ('embedding disabled (150)', {'e': 'error', 'c': 150}),
      ('the API script not loading', {'e': 'error', 'c': -1}),
      ('autoplay blocked', {'e': 'blocked'}),
    ]) {
      test('$name fails it like a broken clip', () async {
        await v.initialize();
        var told = 0;
        v.addListener(() => told++);
        bridge.post(message);
        expect(v.failed, isTrue);
        expect(v.ready, isFalse);
        expect(v.pictureUp, isFalse);
        expect(told, greaterThan(0));
      });
    }

    test('messages not shaped as expected are ignored', () async {
      await v.initialize();
      bridge.postRaw('not json');
      bridge.postRaw('[1,2]');
      bridge.post({'e': 'state', 's': 'one'});
      bridge.post({'e': 'tick', 't': 'x'});
      expect(v.failed, isFalse);
      expect(v.playing, isFalse);
    });

    test('calls reach the page\'s functions; volume 0 is a mute', () async {
      await v.initialize();
      await v.play();
      await v.setVolume(0);
      await v.setVolume(0.3);
      await v.pause();
      await v.seekTo(Duration.zero);
      await v.setLooping(true);
      expect(bridge.scripts, [
        'reelPlay()',
        'reelVolume(0.0)',
        'reelVolume(0.3)',
        'reelPause()',
        'reelSeek(0.0)',
        'reelLoop(true)',
      ]);
    });

    test('dispose stops the player in the page, then the page goes; nothing runs after', () async {
      await v.initialize();
      await v.dispose();
      expect(bridge.scripts.last, 'reelStop()');
      expect(bridge.released, isTrue);
      await v.play();
      expect(bridge.scripts.last, 'reelStop()');
    });

    // Real time: the subscription's cancel completes outside a fake zone.
    test('a page that never answers the stop is still let go, in bounded time', () async {
      final stuck = _StuckBridge();
      final s = YouTubeFeedVideo('AbCdEfGhIj1', origin: () async => 'https://com.example.reelapp', bridge: stuck);
      final sw = Stopwatch()..start();
      await s.dispose().timeout(YouTubeFeedVideo.stopTimeout * 3);
      expect(sw.elapsed, greaterThanOrEqualTo(YouTubeFeedVideo.stopTimeout));
      expect(stuck.released, isTrue);
    });

    test('a second dispose while the first runs does nothing', () async {
      final first = v.dispose();
      final second = v.dispose();
      await Future.wait([first, second]);
      expect(bridge.scripts.where((s) => s == 'reelStop()'), hasLength(1));
      expect(bridge.releases, 1);
    });
  });

  group('the feed with a player page', () {
    late Map<String, FeedVideo> made;
    late List<String> failed;
    late List<String> started;
    late ReelFeedPlayers players;

    ReelFeedPlayers make({Duration? stuckAfter, Duration embedStuckAfter = FeedWatchdog.embedAfter}) => ReelFeedPlayers(
      create: (uri) {
        final id = ReelYouTube.idOf(uri);
        if (id != null) return made[id.substring(4, 5)] = _FakeEmbed(uri);
        return made[uri.pathSegments.last.split('.').first] = _Native();
      },
      riseOver: Duration.zero,
      stuckAfter: stuckAfter,
      embedStuckAfter: embedStuckAfter,
      onFailed: failed.add,
      onStarted: started.add,
    );

    setUp(() {
      made = {};
      failed = [];
      started = [];
      players = make();
    });

    tearDown(() => players.dispose());

    test('a page opens only for the card on screen, never parked ahead or behind', () async {
      players.sync(current: 'a', window: [_native('a', 0), _embed('b', 1), _embed('c', 2), _embed('z', -1)]);
      await _settle();
      expect(made.keys, ['a']);
      players.sync(current: 'b', window: [_embed('b', 0), _native('c', 1), _native('a', -1)]);
      await _settle();
      expect(made.keys, containsAll(['a', 'b']));
      expect((made['b']! as _FakeEmbed).calls, contains('play'));
    });

    test('swiping away lets the page go at once (no audio left behind)', () async {
      players.sync(current: 'b', window: [_embed('b', 0), _native('c', 1)]);
      await _settle();
      final page = made['b']! as _FakeEmbed;
      players.sync(current: 'c', window: [_native('c', 0), _embed('b', -1)]);
      await _settle();
      expect(page.disposed, isTrue);
      expect(players.held, isNot(contains('b')));
    });

    test('a page still loading its player is told to stop when the feed goes away', () async {
      players.sync(current: 'b', window: [_embed('b', 0)]);
      await _settle();
      final page = made['b']! as _FakeEmbed;
      expect(page.playing, isFalse, reason: 'asked to play, its player not up yet');
      await players.pauseAll();
      expect(page.calls.last, 'pause', reason: 'it would start behind the app once its player loads');
    });

    test('it starts silent on every visit, whatever the mute, until the sound control', () async {
      players.sync(current: 'b', window: [_embed('b', 0)]);
      await _settle();
      final page = made['b']! as _FakeEmbed;
      expect(players.muted, isFalse);
      expect(players.quiet, isTrue);
      expect(players.soundOff, isTrue);
      expect(_volumes(page.calls).toSet(), {0.0}, reason: 'never a sound before the tap');
      await players.unquiet();
      expect(players.quiet, isFalse);
      expect(players.soundOff, isFalse);
      expect(_volumes(page.calls).last, 1.0);

      // A mute still silences it, and unmuting brings it back.
      await players.setMuted(true);
      expect(_volumes(page.calls).last, 0.0);
      await players.setMuted(false);
      expect(_volumes(page.calls).last, 1.0);

      // Away and back: a new page, silent again.
      players.sync(current: 'x', window: [_native('x', 0)]);
      await _settle();
      players.sync(current: 'b', window: [_embed('b', 0)]);
      await _settle();
      final again = made['b']! as _FakeEmbed;
      expect(identical(again, page), isFalse);
      expect(players.quiet, isTrue);
      expect(_volumes(again.calls).toSet(), {0.0});
    });

    test('an unmute while silent leaves it silent; only the sound control gives it sound', () async {
      await players.setMuted(true);
      players.sync(current: 'b', window: [_embed('b', 0)]);
      await _settle();
      final page = made['b']! as _FakeEmbed;
      await players.setMuted(false);
      expect(_volumes(page.calls).where((v) => v > 0), isEmpty);
      expect(players.soundOff, isTrue);
    });

    test('a native card on screen is never quiet', () async {
      players.sync(current: 'a', window: [_native('a', 0)]);
      await _settle();
      expect(players.quiet, isFalse);
      expect(players.soundOff, isFalse);
      expect(_volumes((made['a']! as _Native).calls).last, greaterThan(0));
    });

    test('its first play state counts as started, at position 0 (an ad)', () async {
      players.sync(current: 'b', window: [_embed('b', 0)]);
      await _settle();
      (made['b']! as _FakeEmbed).startsPlaying();
      expect(started, ['b']);
    });

    test('an embed error falls back like a failed clip', () async {
      players.sync(current: 'b', window: [_embed('b', 0)]);
      await _settle();
      (made['b']! as _FakeEmbed).breaks();
      await _settle();
      expect(failed, ['b']);
      expect((made['b']! as _FakeEmbed).disposed, isTrue);
    });

    test('the watchdog gives a page longer than a native clip', () {
      fakeAsync((async) {
        final p = make(stuckAfter: const Duration(seconds: 6), embedStuckAfter: const Duration(seconds: 12));
        p.sync(current: 'b', window: [_embed('b', 0)]);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 8));
        expect(failed, isEmpty, reason: 'a native clip would have failed at 6 s');
        async.elapse(const Duration(seconds: 5));
        expect(failed, ['b'], reason: 'asked to play and never played: not a focus loss');
        p.dispose();
      });
    });

    test('a page that plays in time is never timed out', () {
      fakeAsync((async) {
        final p = make(stuckAfter: const Duration(seconds: 6), embedStuckAfter: const Duration(seconds: 12));
        p.sync(current: 'b', window: [_embed('b', 0)]);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 9));
        (made['b']! as _FakeEmbed).startsPlaying();
        async.elapse(const Duration(seconds: 10));
        expect(failed, isEmpty);
        p.dispose();
      });
    });
  });
}
