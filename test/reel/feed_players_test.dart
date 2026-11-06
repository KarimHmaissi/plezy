import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/feed_players.dart';

/// A player that opens at once and remembers what was asked of it.
class _FakeVideo extends ChangeNotifier implements FeedVideo {
  _FakeVideo(this.uri);

  final Uri uri;
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
  Future<void> initialize() async {
    calls.add('init');
    _ready = true;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _playing = true;
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
  }

  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');

  void tick(Duration to) {
    _position = to;
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

FeedClip _clip(String id) => (id: id, uri: Uri.parse('https://cdn.example/$id.mp4'));

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

  setUp(() {
    made = {};
    looped = [];
    started = [];
    failed = [];
    players = ReelFeedPlayers(
      create: (uri) => made[uri.pathSegments.last.split('.').first] = _FakeVideo(uri),
      onLooped: looped.add,
      onStarted: started.add,
      onFailed: failed.add,
    );
  });

  tearDown(() => players.dispose());

  test('the card on screen plays; the next ones open and wait on their first frame', () async {
    players.sync(current: 'a', window: [_clip('a'), _clip('b'), _clip('c')]);
    await _settle();
    expect(made.keys, ['a', 'b', 'c']);
    expect(made['a']!.playing, isTrue);
    expect(made['b']!.ready, isTrue);
    expect(made['b']!.playing, isFalse);
    expect(made['c']!.calls, isNot(contains('play')));
    expect(players.videoFor('b'), isNotNull, reason: 'the next page already has a picture');
  });

  test('a swipe plays the parked player at once; the one left behind holds its frame until settle', () async {
    players.sync(current: 'a', window: [_clip('a'), _clip('b'), _clip('c')]);
    await _settle();
    made['a']!.tick(const Duration(seconds: 12));
    players.sync(current: 'b', window: [_clip('b'), _clip('c'), _clip('d'), _clip('a')]);
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
    players.sync(current: 'a', window: [_clip('a'), _clip('b'), _clip('c')]);
    await _settle();
    made['a']!.tick(const Duration(seconds: 12));
    // Past the middle and back again before the page settles.
    players.sync(current: 'b', window: [_clip('b'), _clip('c'), _clip('d'), _clip('a')]);
    await _settle();
    made['b']!.tick(const Duration(milliseconds: 300));
    players.sync(current: 'a', window: [_clip('a'), _clip('b'), _clip('c')]);
    await _settle();
    expect(made['a']!.playing, isTrue);
    expect(made['a']!.position, const Duration(seconds: 12));
    expect(made['b']!.playing, isFalse);

    await players.settle();
    expect(made['a']!.position, const Duration(seconds: 12));
    expect(made['b']!.position, Duration.zero, reason: 'the card that peeked in starts from the top next time');
  });

  test('the card left behind is told once per change of card', () async {
    final left = <String>[];
    final p = ReelFeedPlayers(create: _FakeVideo.new, onLeft: left.add);
    addTearDown(p.dispose);
    p.sync(current: 'a', window: [_clip('a'), _clip('b')]);
    await _settle();
    p.sync(current: 'a', window: [_clip('a'), _clip('b')]);
    p.sync(current: 'b', window: [_clip('b'), _clip('a')]);
    await _settle();
    expect(left, ['a']);
    await p.releaseAll();
    expect(left, ['a', 'b']);
  });

  test("each card's page hears only about its own card", () async {
    players.sync(current: 'a', window: [_clip('a'), _clip('b'), _clip('c')]);
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

    players.sync(current: 'b', window: [_clip('b'), _clip('c'), _clip('a')]);
    await _settle();
    expect(a.value.current, isFalse);
    expect(a.value.paused, isFalse);
    expect(players.card('b').value.current, isTrue);
    a.removeListener(onA);
    c.removeListener(onC);
  });

  test('players that leave the window are disposed', () async {
    players.sync(current: 'a', window: [_clip('a'), _clip('b'), _clip('c')]);
    await _settle();
    players.sync(current: 'c', window: [_clip('c'), _clip('d'), _clip('e'), _clip('b')]);
    await _settle();
    expect(made['a']!.disposed, isTrue);
    expect(players.held.toSet(), {'b', 'c', 'd', 'e'});
  });

  test('memory pressure keeps only the card on screen, then none', () async {
    players.sync(current: 'a', window: [_clip('a'), _clip('b'), _clip('c')], memoryLevel: 1);
    await _settle();
    expect(players.held, ['a']);
    players.sync(current: 'a', window: [_clip('a'), _clip('b'), _clip('c')], memoryLevel: 2);
    await _settle();
    expect(players.held, isEmpty);
    expect(made['a']!.disposed, isTrue);
  });

  test('a tap pauses and resumes; mute reaches every player', () async {
    players.sync(current: 'a', window: [_clip('a'), _clip('b')]);
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
    players.sync(current: 'a', window: [_clip('a')]);
    await _settle();
    made['a']!.tick(const Duration(seconds: 80));
    made['a']!.tick(const Duration(milliseconds: 200));
    expect(looped, ['a']);
  });

  test('before real playback every decoder is let go', () async {
    players.sync(current: 'a', window: [_clip('a'), _clip('b')]);
    await _settle();
    await players.releaseAll();
    expect(made.values.every((v) => v.disposed), isTrue);
    expect(players.held, isEmpty);
  });

  test('the card on screen reports playing once its position moves, again after a revisit', () async {
    players.sync(current: 'a', window: [_clip('a'), _clip('b')]);
    await _settle();
    expect(started, isEmpty, reason: 'play() alone is not a picture');
    made['a']!.tick(const Duration(milliseconds: 100));
    made['a']!.tick(const Duration(milliseconds: 200));
    made['b']!.tick(const Duration(milliseconds: 100));
    expect(started, ['a'], reason: 'once, and never for a parked card');

    players.sync(current: 'b', window: [_clip('b'), _clip('a')]);
    await _settle();
    made['b']!.tick(const Duration(milliseconds: 100));
    players.sync(current: 'a', window: [_clip('a'), _clip('b')]);
    await _settle();
    made['a']!.tick(const Duration(milliseconds: 100));
    expect(started, ['a', 'b', 'a']);
  });

  test('a player that breaks on screen is reported once', () async {
    players.sync(current: 'a', window: [_clip('a'), _clip('b')]);
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
}
