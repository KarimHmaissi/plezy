import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/feed_players.dart';

/// A player that opens at once and remembers what was asked of it.
class _FakeVideo extends ChangeNotifier implements FeedVideo {
  _FakeVideo(this.uri, {this.loaded, this.gate});

  final Uri uri;

  /// Holds the open until completed; one never completed is an open that
  /// never finishes (a slow link).
  final Completer<void>? gate;

  /// How far it has loaded once open; null loads the whole clip at once.
  Duration? loaded;
  final calls = <String>[];
  bool _ready = false;
  bool _playing = false;
  bool disposed = false;
  Duration _position = Duration.zero;

  @override
  bool get ready => _ready;
  bool broken = false;

  @override
  bool get failed => broken;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Duration get position => _position;
  @override
  Duration get duration => const Duration(seconds: 90);
  @override
  bool get playing => _playing;
  @override
  bool buffering = false;
  @override
  Duration get buffered => _ready ? (loaded ?? duration) : Duration.zero;

  @override
  Future<void> initialize() async {
    calls.add('init');
    await gate?.future;
    _ready = true;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    // As the plugin does: a play from the end starts at the top.
    if (completed) _position = Duration.zero;
    completed = false;
    _playing = true;
  }

  @override
  bool completed = false;

  @override
  Future<void> setLooping(bool looping) async => calls.add('loop $looping');

  /// The clip reaches its end with looping off: the plugin pauses on the
  /// last frame.
  void end() {
    _playing = false;
    _position = duration;
    completed = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing = false;
  }

  @override
  Future<void> seekTo(Duration position) async {
    calls.add('seek ${position.inSeconds}');
    _position = position;
    completed = position == duration;
  }

  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');

  void tick(Duration to) {
    _position = to;
    notifyListeners();
  }

  /// The system stops or restarts it (audio focus lost or given back).
  void systemPlaying(bool playing) {
    _playing = playing;
    notifyListeners();
  }

  /// A stall mid-play: the plugin reports it as buffering and not playing
  /// until data comes ([stall] false).
  void stall(bool stalled) {
    buffering = stalled;
    _playing = !stalled;
    notifyListeners();
  }

  /// The plugin's buffer poll.
  void loadTo(Duration to) {
    loaded = to;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    super.dispose();
  }

  @override
  Widget view() => const SizedBox();
}

FeedClip _clip(String id, int offset) => (id: id, uri: Uri.parse('https://cdn.example/$id.mp4'), offset: offset);

/// The view's window: the card on screen, the ones [ahead] of it, and the
/// one [behind].
List<FeedClip> _win(String current, [List<String> ahead = const [], String? behind]) => [
  _clip(current, 0),
  for (var i = 0; i < ahead.length; i++) _clip(ahead[i], i + 1),
  if (behind != null) _clip(behind, -1),
];

/// The volumes set on [v], in order.
List<double> _volumes(_FakeVideo v) => [
  for (final c in v.calls)
    if (c.startsWith('volume ')) double.parse(c.substring(7)),
];

/// What [v] was asked from its last play on: volumes and pauses.
List<String> _since(_FakeVideo v, String call) => v.calls.sublist(v.calls.lastIndexOf(call));

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Map<String, _FakeVideo> made;
  late List<String> looped;
  late List<String> started;
  late List<String> failed;
  late ReelFeedPlayers players;

  /// How far each new player has loaded once open (null: the whole clip).
  Duration? loadedAtOpen;

  /// Cards whose open never finishes.
  late Set<String> hanging;

  setUp(() {
    loadedAtOpen = null;
    hanging = {};
    made = {};
    looped = [];
    started = [];
    failed = [];
    players = ReelFeedPlayers(
      create: (uri) {
        final id = uri.pathSegments.last.split('.').first;
        return made[id] = _FakeVideo(uri, loaded: loadedAtOpen, gate: hanging.contains(id) ? Completer<void>() : null);
      },
      onLooped: looped.add,
      onStarted: started.add,
      onFailed: failed.add,
    );
  });

  tearDown(() => players.dispose());

  test('the card on screen plays; the next ones open and wait on their first frame', () async {
    players.sync(current: 'a', window: _win('a', ['b', 'c']));
    await _settle();
    expect(made.keys, ['a', 'b', 'c']);
    expect(made['a']!.playing, isTrue);
    expect(made['b']!.ready, isTrue);
    expect(made['b']!.playing, isFalse);
    expect(made['c']!.calls, isNot(contains('play')));
    expect(players.videoFor('b'), isNotNull, reason: 'the next page already has a picture');
  });

  test('a swipe plays the parked player at once; the one left behind holds its frame until settle', () async {
    players.sync(current: 'a', window: _win('a', ['b', 'c']));
    await _settle();
    made['a']!.tick(const Duration(seconds: 12));
    players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'));
    await _settle();
    expect(made['b']!.playing, isTrue);
    expect(made['b']!.calls.where((c) => c == 'init'), hasLength(1), reason: 'not opened again');
    expect(made['a']!.playing, isFalse);
    expect(made['a']!.position, const Duration(seconds: 12), reason: 'still half on screen: no jump to frame 0');
    expect(made['a']!.calls.where((c) => c.startsWith('seek')), isEmpty);
    expect(made.keys, contains('d'));

    await players.settle();
    expect(made['a']!.position, Duration.zero, reason: 'off screen once the page rests');
    expect(made['b']!.playing, isTrue, reason: 'the card on screen is left alone');
    expect(made['b']!.calls.where((c) => c.startsWith('seek')), isEmpty);
  });

  test('a drag that comes back plays the first card on from where it held', () async {
    players.sync(current: 'a', window: _win('a', ['b', 'c']));
    await _settle();
    made['a']!.tick(const Duration(seconds: 12));
    // Past the middle and back again before the page settles.
    players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'));
    await _settle();
    made['b']!.tick(const Duration(milliseconds: 300));
    players.sync(current: 'a', window: _win('a', ['b', 'c']));
    await _settle();
    expect(made['a']!.playing, isTrue);
    expect(made['a']!.position, const Duration(seconds: 12));
    expect(made['b']!.playing, isFalse);

    await players.settle();
    expect(made['a']!.position, const Duration(seconds: 12));
    expect(made['b']!.position, Duration.zero, reason: 'the card that peeked in starts from the top next time');
  });

  test('a swipe back onto a card while the settle parks it never rewinds it on screen', () async {
    players.sync(current: 'a', window: _win('a', ['b', 'c']));
    await _settle();
    players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'));
    await _settle();
    made['a']!.tick(const Duration(seconds: 12));
    // The page rests on b; before the settle has parked a, a fast swipe
    // brings a back past the middle.
    final settling = players.settle();
    players.sync(current: 'a', window: _win('a', ['b', 'c']));
    await settling;
    await _settle();
    expect(made['a']!.position, const Duration(seconds: 12), reason: 'on screen again: no jump to frame 0');
    expect(made['a']!.calls.where((c) => c.startsWith('seek')), isEmpty);
  });

  test('the card left behind is told once per change of card', () async {
    final left = <String>[];
    final p = ReelFeedPlayers(create: _FakeVideo.new, onLeft: left.add);
    addTearDown(p.dispose);
    p.sync(current: 'a', window: _win('a', ['b']));
    await _settle();
    p.sync(current: 'a', window: _win('a', ['b']));
    p.sync(current: 'b', window: _win('b', [], 'a'));
    await _settle();
    expect(left, ['a']);
    await p.releaseAll();
    expect(left, ['a', 'b']);
  });

  test("each card's page hears only about its own card", () async {
    players.sync(current: 'a', window: _win('a', ['b', 'c']));
    final a = players.card('a'), c = players.card('c');
    var aHeard = 0, cHeard = 0;
    void onA() => aHeard++;
    void onC() => cHeard++;
    a.addListener(onA);
    c.addListener(onC);
    await _settle();
    expect(a.value.current, isTrue);
    expect(a.value.video, isNotNull);
    expect(c.value.current, isFalse);
    expect(c.value.video, isNotNull, reason: 'parked on its first frame');

    aHeard = cHeard = 0;
    await players.togglePause();
    expect(a.value.paused, isTrue);
    expect(aHeard, 1);
    expect(cHeard, 0, reason: 'a pause on card a does not rebuild card c');

    players.sync(current: 'b', window: _win('b', ['c'], 'a'));
    await _settle();
    expect(a.value.current, isFalse);
    expect(a.value.paused, isFalse);
    expect(players.card('b').value.current, isTrue);
    a.removeListener(onA);
    c.removeListener(onC);
  });

  test('players that leave the window are disposed', () async {
    players.sync(current: 'a', window: _win('a', ['b', 'c']));
    await _settle();
    players.sync(current: 'c', window: _win('c', ['d', 'e'], 'b'));
    await _settle();
    expect(made['a']!.disposed, isTrue);
    expect(players.held.toSet(), {'b', 'c', 'd', 'e'});
  });

  test('memory pressure keeps only the card on screen, then none', () async {
    players.sync(current: 'a', window: _win('a', ['b', 'c']), memoryLevel: 1);
    await _settle();
    expect(players.held, ['a']);
    players.sync(current: 'a', window: _win('a', ['b', 'c']), memoryLevel: 2);
    await _settle();
    expect(players.held, isEmpty);
    expect(made['a']!.disposed, isTrue);
  });

  test('a tap pauses and resumes; mute reaches every player', () async {
    players.sync(current: 'a', window: _win('a', ['b']));
    await _settle();
    await players.togglePause();
    expect(made['a']!.playing, isFalse);
    expect(players.paused, isTrue);
    await players.togglePause();
    expect(made['a']!.playing, isTrue);
    await players.setMuted(true);
    expect(made['a']!.calls.last, 'volume 0.0');
    expect(made['b']!.calls.last, 'volume 0.0');
  });

  test('a loop back to the start counts as one play-through', () async {
    players.sync(current: 'a', window: _win('a'));
    await _settle();
    made['a']!.tick(const Duration(seconds: 80));
    made['a']!.tick(const Duration(milliseconds: 200));
    expect(looped, ['a']);
  });

  test('before real playback every decoder is let go', () async {
    players.sync(current: 'a', window: _win('a', ['b']));
    await _settle();
    await players.releaseAll();
    expect(made.values.every((v) => v.disposed), isTrue);
    expect(players.held, isEmpty);
  });

  group('release paths never wait for an open (V2-06)', () {
    test('Watch lets every player go while one is still opening', () async {
      hanging = {'b'};
      players.sync(current: 'a', window: _win('a', ['b', 'c']));
      await _settle();
      expect(made['b']!.calls, ['init'], reason: 'b is stuck opening');
      var released = false;
      unawaited(players.releaseAll().then((_) => released = true));
      await _settle();
      expect(released, isTrue);
      expect(made.values.every((v) => v.disposed), isTrue);
      expect(players.held, isEmpty);
    });

    test('a memory trim lets go of a neighbour that is still opening', () async {
      hanging = {'b'};
      players.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      players.sync(current: 'a', window: _win('a', ['b']), memoryLevel: 1);
      await _settle();
      expect(made['b']!.disposed, isTrue);
      expect(players.held, ['a']);
    });

    test('a player let go mid-open does not hold up the ones after it', () async {
      // A still on screen: the whole window opens at once, in order, so c
      // waits on b.
      hanging = {'b'};
      players.sync(current: 'a', window: [_clip('b', 1), _clip('c', 2)]);
      await _settle();
      expect(made['c']!.calls, isEmpty, reason: 'c waits for b to open');
      players.sync(current: 'a', window: [_clip('c', 1), _clip('d', 2)]);
      await _settle();
      expect(made['b']!.disposed, isTrue);
      expect(made['c']!.calls, contains('init'));
      expect(made['c']!.ready, isTrue);
      expect(made['d']!.ready, isTrue);
    });
  });

  test('the card on screen reports playing once its position moves, again after a revisit', () async {
    players.sync(current: 'a', window: _win('a', ['b']));
    await _settle();
    expect(started, isEmpty, reason: 'play() alone is not a picture');
    made['a']!.tick(const Duration(milliseconds: 100));
    made['a']!.tick(const Duration(milliseconds: 200));
    made['b']!.tick(const Duration(milliseconds: 100));
    expect(started, ['a'], reason: 'once, and never for a parked card');

    players.sync(current: 'b', window: _win('b', [], 'a'));
    await _settle();
    made['b']!.tick(const Duration(milliseconds: 100));
    players.sync(current: 'a', window: _win('a', ['b']));
    await _settle();
    made['a']!.tick(const Duration(milliseconds: 100));
    expect(started, ['a', 'b', 'a']);
  });

  test('a player that breaks on screen is reported once', () async {
    players.sync(current: 'a', window: _win('a', ['b']));
    await _settle();
    made['b']!
      ..broken = true
      ..tick(Duration.zero);
    made['a']!
      ..broken = true
      ..tick(Duration.zero)
      ..tick(Duration.zero);
    expect(failed, ['a']);
    expect(started, isEmpty);
  });

  group('the window opens by what the card on screen has loaded (V2-08)', () {
    const s1 = Duration(seconds: 1);

    test('on Wi-Fi: the next card at 6 s loaded, the one after and the one behind at 10 s', () async {
      loadedAtOpen = s1;
      players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'));
      await _settle();
      expect(players.held, ['b'], reason: 'the card on screen has its first second to itself');

      made['b']!.loadTo(const Duration(seconds: 5));
      await _settle();
      expect(players.held, ['b']);

      made['b']!.loadTo(const Duration(seconds: 6));
      await _settle();
      expect(players.held.toSet(), {'b', 'c'});
      expect(made['c']!.ready, isTrue, reason: 'parked on its first frame');

      made['b']!.loadTo(const Duration(seconds: 10));
      await _settle();
      expect(players.held.toSet(), {'a', 'b', 'c', 'd'});
    });

    test('loaded is counted ahead of where the clip is playing', () async {
      loadedAtOpen = const Duration(seconds: 8);
      players.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      expect(players.held.toSet(), {'a', 'b'});

      // Already open: a buffer that falls behind the playhead closes nothing.
      made['a']!.tick(const Duration(seconds: 7));
      await _settle();
      expect(players.held.toSet(), {'a', 'b'});
    });

    test('a card that has played 3 s opens the next even on a slow link', () async {
      loadedAtOpen = s1;
      players.sync(current: 'a', window: _win('a', ['b', 'c']));
      await _settle();
      made['a']!.tick(const Duration(seconds: 2));
      await _settle();
      expect(players.held, ['a']);
      made['a']!
        ..loadTo(const Duration(seconds: 4))
        ..tick(const Duration(seconds: 3));
      await _settle();
      expect(players.held.toSet(), {'a', 'b'}, reason: 'the one after waits for 10 s loaded');
    });

    test('a short clip loaded to its end opens the whole window', () async {
      loadedAtOpen = const Duration(seconds: 89, milliseconds: 600);
      players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'));
      await _settle();
      expect(players.held.toSet(), {'a', 'b', 'c', 'd'});
    });

    test('a card on screen with no clip, or a broken one, holds nothing back', () async {
      loadedAtOpen = s1;
      // An AI card on screen: the next two have clips.
      players.sync(current: 'still', window: [_clip('b', 1), _clip('c', 2)]);
      await _settle();
      expect(players.held.toSet(), {'b', 'c'});

      final p = ReelFeedPlayers(create: (uri) => _FakeVideo(uri, loaded: s1)..broken = true);
      addTearDown(p.dispose);
      p.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      expect(p.held.toSet(), {'a', 'b'});
    });

    test('on a metered link only the card on screen and the next, however much is loaded', () async {
      players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'), metered: true);
      await _settle();
      expect(players.held.toSet(), {'b', 'c'});
    });

    test('on a metered link the card left behind holds its frame until the page settles', () async {
      players.sync(current: 'a', window: _win('a', ['b', 'c']), metered: true);
      await _settle();
      made['a']!.tick(const Duration(seconds: 12));
      players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'), metered: true);
      await _settle();
      expect(players.held.toSet(), {'a', 'b', 'c'});
      expect(made['a']!.disposed, isFalse, reason: 'still half on screen');
      expect(made['a']!.position, const Duration(seconds: 12));

      await players.settle();
      await _settle();
      expect(players.held.toSet(), {'b', 'c'});
      expect(made['a']!.disposed, isTrue);
    });

    test('Wi-Fi dropping to mobile data lets the far players go; Wi-Fi back opens them again', () async {
      players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'));
      await _settle();
      expect(players.held.toSet(), {'a', 'b', 'c', 'd'});

      players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'), metered: true);
      await _settle();
      expect(players.held.toSet(), {'b', 'c'});
      expect(made['a']!.disposed && made['d']!.disposed, isTrue);
      expect(made['b']!.playing, isTrue, reason: 'the card on screen is left alone');

      players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'));
      await _settle();
      expect(players.held.toSet(), {'a', 'b', 'c', 'd'});
    });

    test('the window opening further never restarts a card paused by a tap', () async {
      loadedAtOpen = s1;
      players.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      await players.togglePause();
      made['a']!.loadTo(const Duration(seconds: 6));
      await _settle();
      expect(players.held.toSet(), {'a', 'b'});
      expect(made['a']!.playing, isFalse);
      expect(made['b']!.playing, isFalse);
    });

    test('each new card on screen stages its window again', () async {
      loadedAtOpen = s1;
      players.sync(current: 'a', window: _win('a', ['b', 'c']));
      await _settle();
      made['a']!.loadTo(const Duration(seconds: 10));
      await _settle();
      expect(players.held.toSet(), {'a', 'b', 'c'});

      // b was parked with only a second loaded: d waits for it.
      players.sync(current: 'b', window: _win('b', ['c', 'd'], 'a'));
      await _settle();
      expect(players.held.toSet(), {'a', 'b', 'c'});
      made['b']!.loadTo(const Duration(seconds: 10));
      await _settle();
      expect(players.held.toSet(), {'a', 'b', 'c', 'd'});
    });
  });

  group('loudness between clips: the phone ramp (V2-19)', () {
    test('the card on screen starts at 30% and rises to full over about 200 ms', () {
      fakeAsync((async) {
        players.sync(current: 'a', window: _win('a', ['b']));
        async.flushMicrotasks();
        final a = made['a']!;
        expect(a.calls.sublist(a.calls.indexOf('init')), [
          'init',
          'volume 0.3',
          // Loop mode for the visit (V2-47), set before the first play.
          'loop true',
          'play',
        ], reason: 'quiet before the first sound');

        async.elapse(const Duration(milliseconds: 100));
        final mid = _volumes(a).last;
        expect(mid, greaterThan(FeedRamp.from));
        expect(mid, lessThan(1.0));

        async.elapse(const Duration(milliseconds: 100));
        final vs = _volumes(a);
        expect(vs.last, 1.0);
        expect(vs, hasLength(1 + FeedRamp.steps));
        for (var i = 1; i < vs.length; i++) {
          expect(vs[i], greaterThan(vs[i - 1]), reason: 'it only rises');
        }

        expect(made['b']!.calls, isNot(contains('play')));
        expect(_volumes(made['b']!), [FeedRamp.from], reason: 'parked, never full');
        unawaited(players.releaseAll());
        async.flushMicrotasks();
      });
    });

    test('a swipe silences the card left before it is parked; the new card rises without waiting', () {
      fakeAsync((async) {
        players.sync(current: 'a', window: _win('a', ['b']));
        async.elapse(FeedRamp.over * 2);
        final a = made['a']!, b = made['b']!;

        players.sync(current: 'b', window: _win('b', [], 'a'));
        async.flushMicrotasks();
        final silenced = a.calls.lastIndexOf('volume 0.0');
        expect(silenced, greaterThan(a.calls.indexOf('play')));
        final after = a.calls.sublist(silenced + 1);
        expect(after, isNotEmpty);
        expect(after, everyElement('pause'), reason: 'silent, then parked');
        expect(_since(b, 'play'), ['play'], reason: 'already at 30%: no volume call ahead of the play');
        expect(_volumes(b).last, FeedRamp.from);

        async.elapse(FeedRamp.over);
        expect(_volumes(b).last, 1.0);
        expect(_volumes(a).last, 0.0, reason: 'the card left stays silent');
        unawaited(players.releaseAll());
        async.flushMicrotasks();
      });
    });

    test('a swipe mid-rise stops the rise on the card left', () {
      fakeAsync((async) {
        players.sync(current: 'a', window: _win('a', ['b']));
        async.elapse(const Duration(milliseconds: 70));
        players.sync(current: 'b', window: _win('b', [], 'a'));
        async.elapse(FeedRamp.over * 2);
        final a = _volumes(made['a']!);
        expect(a, isNot(contains(1.0)));
        expect(a.last, 0.0);
        unawaited(players.releaseAll());
        async.flushMicrotasks();
      });
    });

    test('a drag that comes back brings the first card in quietly again', () {
      fakeAsync((async) {
        players.sync(current: 'a', window: _win('a', ['b']));
        async.elapse(FeedRamp.over * 2);
        players.sync(current: 'b', window: _win('b', [], 'a'));
        async.flushMicrotasks();
        players.sync(current: 'a', window: _win('a', ['b']));
        async.flushMicrotasks();
        final a = made['a']!;
        expect(_since(a, 'play').first, 'play');
        expect(a.calls[a.calls.lastIndexOf('play') - 1], 'volume 0.3');
        async.elapse(FeedRamp.over);
        expect(_volumes(a).last, 1.0);
        unawaited(players.releaseAll());
        async.flushMicrotasks();
      });
    });

    test('unmute rises on the card on screen instead of jumping; parked cards stay silent', () {
      fakeAsync((async) {
        players.sync(current: 'a', window: _win('a', ['b']));
        async.elapse(FeedRamp.over * 2);
        unawaited(players.setMuted(true));
        async.flushMicrotasks();
        expect(_volumes(made['a']!).last, 0.0);
        expect(_volumes(made['b']!).last, 0.0);

        final before = _volumes(made['a']!).length;
        unawaited(players.setMuted(false));
        async.flushMicrotasks();
        expect(_volumes(made['a']!).sublist(before), [FeedRamp.from], reason: 'no jump to full');
        async.elapse(FeedRamp.over);
        expect(_volumes(made['a']!).last, 1.0);
        expect(_volumes(made['b']!).last, 0.0, reason: 'b is not on screen');

        // b comes on screen later: it rises like any other card.
        players.sync(current: 'b', window: _win('b', [], 'a'));
        async.flushMicrotasks();
        final b = made['b']!;
        expect(b.calls[b.calls.lastIndexOf('play') - 1], 'volume 0.3');
        async.elapse(FeedRamp.over);
        expect(_volumes(b).last, 1.0);
        unawaited(players.releaseAll());
        async.flushMicrotasks();
      });
    });

    test('muted, a new card plays silent and a mute mid-rise holds it silent', () {
      fakeAsync((async) {
        players.sync(current: 'a', window: _win('a', ['b']));
        async.elapse(const Duration(milliseconds: 70));
        unawaited(players.setMuted(true));
        async.elapse(FeedRamp.over * 2);
        expect(_volumes(made['a']!).last, 0.0, reason: 'the rise stopped at the mute');

        players.sync(current: 'b', window: _win('b', [], 'a'));
        async.elapse(FeedRamp.over * 2);
        expect(made['b']!.playing, isTrue);
        expect(_volumes(made['b']!).last, 0.0);
        unawaited(players.releaseAll());
        async.flushMicrotasks();
      });
    });
  });

  group('audio focus and the screen (V2-22)', () {
    late List<bool> awake;
    late ReelFeedPlayers p;

    setUp(() {
      awake = [];
      made = {};
      p = ReelFeedPlayers(
        create: (uri) => made[uri.pathSegments.last.split('.').first] = _FakeVideo(uri),
        keepAwake: (on) async => awake.add(on),
        riseOver: Duration.zero,
      );
    });

    tearDown(() => p.dispose());

    test('the screen stays on only while the card on screen plays', () async {
      p.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      expect(awake, [true]);

      await p.togglePause();
      expect(awake, [true, false], reason: 'a tap pause lets the screen time out');
      await p.togglePause();
      expect(awake, [true, false, true]);

      // A swipe onto a card with no clip (a still).
      p.sync(current: 's', window: _win('b', [], 'a').where((w) => w.id != 'b').toList());
      await _settle();
      expect(awake.last, isFalse);

      p.sync(current: 'b', window: _win('b', [], 'a'));
      await _settle();
      expect(awake.last, isTrue);
      await p.releaseAll();
      expect(awake.last, isFalse);
      expect(awake.where((on) => on).length, awake.where((on) => !on).length, reason: 'every hold let go');
    });

    test('a card that stops by itself lets the screen go and is not played again by a re-sync', () async {
      p.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      final a = made['a']!;

      a.systemPlaying(false);
      await _settle();
      expect(awake.last, isFalse);

      // The controller changes and the feed re-syncs: no play, so the
      // focus is not taken back from the app that took it.
      p.sync(current: 'a', window: _win('a', ['b']));
      p.sync(current: 'a', window: _win('a', ['b', 'c']));
      await _settle();
      expect(a.playing, isFalse);
      expect(a.calls.where((c) => c == 'play'), hasLength(1));

      // A screen switch re-syncs with resume: it plays on (V2-65).
      p.sync(current: 'a', window: _win('a', ['b']), resume: true);
      await _settle();
      expect(a.playing, isTrue);
      a.systemPlaying(false);
      await _settle();

      // The system gives it back (a call ended): the screen is held again.
      a.systemPlaying(true);
      await _settle();
      expect(awake.last, isTrue);
    });

    test('a stall mid-play keeps the screen on', () async {
      p.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      final a = made['a']!;
      expect(awake, [true]);

      a.stall(true);
      await _settle();
      expect(awake, [true], reason: 'letting go mid-stall would dim an untouched screen');
      a.stall(false);
      await _settle();
      expect(awake, [true]);

      // A tap pause lets it go, stall or not.
      await p.togglePause();
      a.stall(true);
      await _settle();
      expect(awake.last, isFalse);
    });

    test('a card that stopped by itself plays again on a tap, or on the next visit', () async {
      p.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      final a = made['a']!;
      a.systemPlaying(false);
      await _settle();

      await p.togglePause();
      await p.togglePause();
      expect(a.playing, isTrue, reason: 'a tap brings it back');

      a.systemPlaying(false);
      p.sync(current: 'b', window: _win('b', [], 'a'));
      await _settle();
      p.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      expect(a.playing, isTrue, reason: 'swiped away and back: a new visit plays');
    });

    test('everything let go waits for the screen to be let go', () async {
      final gate = Completer<void>();
      final q = ReelFeedPlayers(
        create: _FakeVideo.new,
        keepAwake: (on) => on ? Future.value() : gate.future,
        riseOver: Duration.zero,
      );
      q.sync(current: 'a', window: _win('a'));
      await _settle();
      var done = false;
      unawaited(q.releaseAll().then((_) => done = true));
      await _settle();
      expect(done, isFalse, reason: 'real playback must not take the screen first');
      gate.complete();
      await _settle();
      expect(done, isTrue);
      q.dispose();
    });

    test('letting go of the feed for good lets the screen go', () async {
      p.sync(current: 'a', window: _win('a'));
      await _settle();
      expect(awake, [true]);
      p.dispose();
      await _settle();
      expect(awake, [true, false]);
      // tearDown disposes again; make that a no-op.
      p = ReelFeedPlayers(create: _FakeVideo.new);
    });
  });
  group('when a clip ends (V2-47)', () {
    late ReelFeedPlayers q;
    late Map<String, _FakeVideo> vids;
    late List<String> plays, ended;
    late List<bool> awake;
    int? times;

    ReelFeedPlayers make() => ReelFeedPlayers(
      create: (uri) {
        final id = uri.pathSegments.last.split('.').first;
        return vids[id] = _FakeVideo(uri);
      },
      plays: () => times,
      onLooped: plays.add,
      keepAwake: (on) async => awake.add(on),
      riseOver: Duration.zero,
    );

    setUp(() {
      vids = {};
      plays = [];
      ended = [];
      awake = [];
      times = 2;
      q = make();
      q.ended.listen(ended.add);
    });

    tearDown(() => q.dispose());

    /// Plays [v] from the top through to a gapless loop back to the start.
    void playThrough(_FakeVideo v) {
      v
        ..tick(const Duration(seconds: 5))
        ..tick(const Duration(seconds: 85))
        ..tick(const Duration(milliseconds: 200));
    }

    test('twice then hold: loops once without a gap, then holds the last frame for Replay', () async {
      q.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      final a = vids['a']!;
      expect(a.calls, containsAllInOrder(['loop true', 'play']), reason: 'the first play loops into the second');

      playThrough(a);
      await _settle();
      expect(plays, ['a']);
      expect(a.calls.last, 'loop false', reason: 'the second play stops on its last frame');
      expect(q.card('a').value.held, isFalse);

      a
        ..tick(const Duration(seconds: 40))
        ..end();
      await _settle();
      expect(plays, ['a', 'a']);
      expect(ended, ['a']);
      expect(q.card('a').value.held, isTrue);
      expect(a.playing, isFalse);
      expect(awake.last, isFalse, reason: 'a held card lets the screen sleep');

      // Further position polls on the held frame count nothing more.
      a.tick(a.duration);
      a.end();
      await _settle();
      expect(ended, ['a']);

      // A screen switch re-syncs with resume: it stays held.
      q.sync(current: 'a', window: _win('a', ['b']), resume: true);
      await _settle();
      expect(a.playing, isFalse);
      expect(q.card('a').value.held, isTrue);
      expect(vids['b']!.playing, isFalse);
    });

    test('Replay, or a tap on the held card, plays it again from the top with its plays afresh', () async {
      q.sync(current: 'a', window: _win('a'));
      await _settle();
      final a = vids['a']!;
      playThrough(a);
      a.end();
      await _settle();
      expect(q.card('a').value.held, isTrue);

      await q.togglePause();
      await _settle();
      expect(q.card('a').value.held, isFalse);
      expect(q.paused, isFalse);
      expect(a.playing, isTrue);
      expect(a.position, Duration.zero);
      expect(_since(a, 'loop true'), ['loop true', 'seek 0', 'play'], reason: 'two plays again');
      expect(awake.last, isTrue);

      playThrough(a);
      a.end();
      await _settle();
      expect(ended, ['a', 'a']);

      await q.replay();
      expect(a.playing, isTrue);
    });

    test('loop plays on for good', () async {
      times = null;
      q.sync(current: 'a', window: _win('a'));
      await _settle();
      final a = vids['a']!;
      for (var i = 0; i < 3; i++) {
        playThrough(a);
      }
      await _settle();
      expect(plays, ['a', 'a', 'a']);
      expect(a.calls.where((c) => c.startsWith('loop')), ['loop true']);
      expect(ended, isEmpty);
      expect(a.playing, isTrue);
    });

    test('next card plays once and tells the feed', () async {
      times = 1;
      q.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      final a = vids['a']!;
      expect(a.calls, containsAllInOrder(['loop false', 'play']));
      a
        ..tick(const Duration(seconds: 5))
        ..end();
      await _settle();
      expect(plays, ['a']);
      expect(ended, ['a']);
      expect(q.card('a').value.held, isTrue);
    });

    test('a pref changed to loop mid-clip plays on at the end instead of holding', () async {
      q.sync(current: 'a', window: _win('a'));
      await _settle();
      final a = vids['a']!;
      playThrough(a);
      await _settle();
      times = null;
      a.end();
      await _settle();
      expect(ended, isEmpty);
      expect(q.card('a').value.held, isFalse);
      expect(a.playing, isTrue);
      expect(a.calls.sublist(a.calls.length - 2), ['loop true', 'play']);
    });

    test('a card that held is played from the top on the next visit', () async {
      q.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      final a = vids['a']!;
      playThrough(a);
      a.end();
      await _settle();
      expect(q.card('a').value.held, isTrue);

      q.sync(current: 'b', window: _win('b', [], 'a'));
      await _settle();
      await q.settle();
      expect(q.card('a').value.held, isFalse);
      q.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      expect(a.playing, isTrue);
      expect(a.position, Duration.zero);
      expect(_since(a, 'loop true'), contains('play'), reason: 'looping set again for a new visit');
    });

    test('a parked card that reaches its end tells nothing', () async {
      q.sync(current: 'a', window: _win('a', ['b']));
      await _settle();
      vids['b']!.end();
      await _settle();
      expect(ended, isEmpty);
      expect(plays, isEmpty);
    });
  });
}
