// The fake engine's controllers are closed in tearDown.
// ignore_for_file: close_sinks
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/customisation/mirror_store.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';

import 'clip_player_test.dart' show FakeClipEngine;

class _Servers implements ReelServers {
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => [
    PlexExtraClip(
      ratingKey: 'x$ratingKey',
      title: 'Trailer',
      partKey: '/services/iva/assets/$ratingKey/video.mp4',
      subtype: 'trailer',
      index: 0,
    ),
  ];

  @override
  String? clipUrl(String serverId, String partKey) => 'https://$serverId.example$partKey';
}

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async => MediaItem(
    id: ratingKey,
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Title $ratingKey',
    serverId: serverId,
  );

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

/// Metadata that isn't there yet the first time each card asks.
class _LateMedia extends _Media {
  final Set<String> _asked = {};

  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async {
    if (_asked.add(ratingKey)) throw StateError('not yet');
    return super.item(serverId, ratingKey);
  }
}

class _Deck extends ReelDeck {
  _Deck(this.id, this.cards);

  @override
  final String id;
  final List<ReelCardData> cards;

  @override
  String get name => 'Deck $id';

  bool keeps = true;

  @override
  bool get keepsSeen => keeps;

  @override
  bool get raw => true;

  @override
  Future<List<ReelCardData>> load() async => cards;
}

IndexedTitle _copy(String id) => IndexedTitle(
  id: 's1:$id',
  serverId: 's1',
  serverName: 'S',
  libraryKey: '1',
  libraryTitle: 'Films',
  ratingKey: id,
  type: 'movie',
  title: 'Title $id',
  genres: '',
  countries: '',
  directors: '',
  writers: '',
  cast: '',
  collections: '',
  groupKey: 'g$id',
  summary: '',
);

ReelCardData _card(String id) => ReelCardData(
  title: ReelTitle(
    titleId: 't$id',
    groupKey: 'g$id',
    title: 'Title $id',
    isShow: false,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: 't$id', groupKey: 'g$id'),
    seen: SeenState.unseen,
  ),
  best: _copy(id),
);

void main() {
  late ForkDatabase db;
  late ReelStore store;
  late FakeClipEngine engine;
  late int engines;
  late int seated;
  late List<String> built;

  ReelController make({
    List<ReelDeck>? decks,
    bool externalClips = false,
    List<MediaItem>? opened,
    DateTime Function()? clock,
    ReelMedia? media,
    ReelWatch? onWatch,
    ReelWatchlist? addToWatchlist,
    bool Function()? reachesTvNow,
  }) => ReelController(
    decks:
        decks ??
        [
          _Deck('a', [_card('1'), _card('2'), _card('3')]),
        ],
    resolver: ClipResolver(
      servers: _Servers(),
      store: store,
      aniList: (_) async => null,
      animeThemes: (_) async => const {},
    ),
    clips: ClipPlayer(
      engine: () {
        engines++;
        return engine = FakeClipEngine();
      },
    ),
    store: store,
    media: media ?? _Media(),
    onWatch: onWatch ?? (_, {required onTv}) async => false,
    addToWatchlist: addToWatchlist ?? (_) async => true,
    onSaved: () async => seated++,
    reachesTvNow: reachesTvNow,
    externalClips: externalClips,
    clock: clock,
    onOpen: (item) async => opened?.add(item),
    deckFor: (id) async {
      built.add(id);
      return id.startsWith('ai:') ? _Deck(id, [_card('9')]) : null;
    },
  );

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    engines = 0;
    seated = 0;
    built = [];
  });

  tearDown(() async {
    await db.close();
  });

  test('the first card plays its trailer and the next one is preloaded', () async {
    final c = make();
    await c.start();
    await Future<void>.delayed(Duration.zero);
    expect(c.current.card?.id, 't1');
    expect(engine.calls, contains('open https://s1.example/services/iva/assets/1/video.mp4'));
    expect(engine.calls, contains('preload https://s1.example/services/iva/assets/2/video.mp4'));
    c.dispose();
  });

  test('Save keeps the pick, seats the Home row and says so', () async {
    final c = make();
    await c.start();
    await c.save();
    expect((await store.freshPicks()).map((p) => p.titleId), ['t1']);
    expect(seated, 1);
    expect(c.toast.value, ReelController.savedOnTv);
    c.dispose();
  });

  group('card actions say where the pick lives', () {
    void readOnlyMirror() => store = ReelStore(
      database: () async => db,
      settings: () async => MirrorCustomisationStore({}, send: (_) => false),
    );

    test('a phone on its own data, with no TV connected, says the pick waits for the next connect', () async {
      final c = make(reachesTvNow: () => false);
      await c.start();
      await c.save();
      expect((await store.freshPicks()).map((p) => p.titleId), ['t1']);
      expect(c.toast.value, ReelController.savedForLater);
      c.dispose();
    });

    test('Save on a mirror that lost its TV says it could not save, and keeps nothing', () async {
      readOnlyMirror();
      final c = make();
      await c.start();
      await expectLater(c.save(), completes);
      expect(await store.freshPicks(), isEmpty);
      expect(seated, 0);
      expect(c.toast.value, ReelController.notConnected);
      c.dispose();
    });

    test('Not for me and Seen it on a read-only mirror leave the card where it was', () async {
      readOnlyMirror();
      final c = make(
        decks: [
          _Deck('a', [_card('1'), _card('2')])..keeps = false,
        ],
      );
      await c.start();
      await expectLater(c.notForMe(), completes);
      expect(c.current.card?.id, 't1');
      await expectLater(c.seenIt(), completes);
      expect(c.current.card?.id, 't1');
      expect(c.toast.value, ReelController.notConnected);
      c.dispose();
    });

    test('a card saved before its metadata landed still goes to the watchlist', () async {
      final mirrored = <String>[];
      final c = make(
        media: _LateMedia(),
        addToWatchlist: (item) async {
          mirrored.add(item.id);
          return true;
        },
      );
      await c.start();
      expect(c.current.item, isNull);
      await c.save();
      await pumpEventQueue();
      expect(mirrored, ['1']);
      c.dispose();
    });

    test('Watch on TV that cannot reach the TV keeps the pick and says when it lands', () async {
      final c = make(onWatch: (_, {required onTv}) async => false, reachesTvNow: () => false);
      await c.start();
      expect(await c.watch(onTv: true), isFalse);
      expect((await store.freshPicks()).map((p) => p.titleId), ['t1']);
      expect(c.toast.value, ReelController.savedForLater);
      c.dispose();
    });
  });

  test('Not for me rests the title and moves on', () async {
    final c = make();
    await c.start();
    await c.notForMe();
    expect(await store.excluded(), contains('t1'));
    expect(c.current.card?.id, 't2');
    c.dispose();
  });

  test('an answer saved after the Reel opened becomes a deck on request', () async {
    final c = make();
    await c.start();
    await c.openDeck('ai:42');
    expect(built, ['ai:42']);
    expect(c.deck.id, 'ai:42');
    expect(c.current.card?.id, 't9');
    await c.openDeck('nope');
    expect(c.deck.id, 'ai:42');
    c.dispose();
  });

  test('memory pressure drops the preload, then releases the core for stills', () async {
    final c = make();
    await c.start();
    await Future<void>.delayed(Duration.zero);
    final first = engine;

    await c.trimMemory();
    expect(c.memoryLevel, 1);
    expect(first.calls.last, 'clearPreloads');
    first.calls.clear();
    await c.step(1);
    await Future<void>.delayed(Duration.zero);
    expect(first.calls.where((x) => x.startsWith('preload ')), isEmpty);

    await c.trimMemory();
    expect(c.memoryLevel, 2);
    expect(first.disposed, isTrue);
    final made = engines;
    await c.step(1);
    await Future<void>.delayed(Duration.zero);
    expect(engines, made, reason: 'no new clip core while stills only');
    expect(c.current.card?.id, 't3');
    c.dispose();
  });

  test('a new visit starts with clips again after memory pressure', () async {
    final c = make();
    await c.start();
    await c.trimMemory(severe: true);
    expect(c.memoryLevel, 2);
    await c.suspend();
    final made = engines;
    await c.start();
    await Future<void>.delayed(Duration.zero);
    expect(c.memoryLevel, 0);
    expect(engines, greaterThan(made), reason: 'the clip core is rebuilt');
    expect(engine.calls.where((x) => x.startsWith('open ')), isNotEmpty);
    c.dispose();
  });

  test('in the phone feed the controller resolves ahead but never drives the clip core', () async {
    final c = make(externalClips: true);
    await c.start();
    await Future<void>.delayed(Duration.zero);
    expect(c.current.clip, isNotNull);
    expect(c.slotAt(1).resolved, isTrue, reason: 'the next card is resolved for its parked player');
    expect(engines, 0, reason: 'the feed plays each page itself');
    await c.step(1);
    expect(c.current.card?.id, 't2');
    expect(engines, 0);
    c.dispose();
  });

  test('a clip the feed played through is recorded as watched to the end', () async {
    final c = make(externalClips: true);
    await c.start();
    c.clipStarted('t1');
    c.clipEnded();
    await c.step(1);
    final events = await store.events(since: DateTime(2000));
    expect(events.map((e) => e.action), contains(ReelAction.toEnd.name));
    c.dispose();
  });

  test('Details opens the title page and records it', () async {
    final opened = <MediaItem>[];
    final c = make(opened: opened);
    await c.start();
    await c.openDetails();
    expect(opened.single.id, '1');
    final events = await store.events(since: DateTime(2000));
    expect(events.map((e) => e.action), contains(ReelAction.details.name));
    c.dispose();
  });

  test('the On TV state carries image paths, never a server URL', () async {
    final c = make();
    await c.start();
    final state = c.remoteState();
    expect(state['active'], isTrue);
    expect(state['deck'], 'a');
    expect((state['card'] as Map)['title'], 'Title 1');
    expect((state['card'] as Map)['server'], 's1');
    expect(jsonEncode(state), isNot(contains('http')));
    await c.suspend();
    expect(c.remoteState()['active'], isFalse);
    c.dispose();
  });

  group('fatigue is timed from the first frame', () {
    late DateTime now;
    DateTime clock() => now;

    setUp(() => now = DateTime.utc(2026, 3, 1, 20));

    Future<List<String>> actions() async => [for (final e in await store.events(since: DateTime(2000))) e.action];

    test('a TV card left while its clip is still loading is unplayed, not a quick skip', () async {
      final c = make(clock: clock);
      await c.start();
      now = now.add(const Duration(milliseconds: 500));
      await c.step(1);
      expect(await actions(), [ReelAction.unplayed.name]);
      expect(await store.quickSkips(), isEmpty);
      c.dispose();
    });

    test('the TV clock starts at the first frame, not when the card was shown', () async {
      final c = make(clock: clock);
      await c.start();
      // A slow open: 5 s of loading, then a first frame, then left 1 s in.
      now = now.add(const Duration(seconds: 5));
      engine.firstFrameCtl.add(null);
      now = now.add(const Duration(seconds: 1));
      await c.step(1);
      expect(await actions(), [ReelAction.quickSkip.name]);

      // The next card plays 9 s after its frame: a sample of 9 s.
      engine.firstFrameCtl.add(null);
      now = now.add(const Duration(seconds: 9));
      await c.step(1);
      final events = await store.events(since: DateTime(2000));
      expect(events.last.action, ReelAction.sampled.name);
      expect(events.last.seconds, 9);
      c.dispose();
    });

    test('a resume from pause before any frame does not start the clock', () async {
      final c = make(clock: clock);
      await c.start();
      await c.clips.pause();
      await c.clips.resume();
      expect(c.clips.phase.value, ClipPhase.playing);
      now = now.add(const Duration(seconds: 1));
      await c.step(1);
      expect(await actions(), [ReelAction.unplayed.name]);
      c.dispose();
    });

    test('a TV clip that failed records nothing about the title', () async {
      final c = make(clock: clock);
      await c.start();
      engine.firstFrameCtl.add(null);
      engine.errorCtl.add(const PlayerError('decoder gave up'));
      now = now.add(const Duration(milliseconds: 800));
      await c.step(1);
      expect(await actions(), [ReelAction.unplayed.name]);
      expect(await store.quickSkips(), isEmpty);
      c.dispose();
    });

    test('a phone card swiped past before its player moved is unplayed', () async {
      final c = make(externalClips: true, clock: clock);
      await c.start();
      now = now.add(const Duration(milliseconds: 700));
      await c.step(1);
      expect(await actions(), [ReelAction.unplayed.name]);
      c.dispose();
    });

    test('the phone clock starts when the feed says the card is playing', () async {
      final c = make(externalClips: true, clock: clock);
      await c.start();
      now = now.add(const Duration(seconds: 4));
      c.clipStarted('t1');
      now = now.add(const Duration(seconds: 1));
      await c.step(1);
      expect(await actions(), [ReelAction.quickSkip.name]);
      c.dispose();
    });

    test('a parked phone player that starts before the card is on screen still counts', () async {
      final c = make(externalClips: true, clock: clock);
      await c.start();
      c.clipStarted('t1');
      // The feed's next player moves before the controller has shown it.
      final stepping = c.step(1);
      c.clipStarted('t2');
      await stepping;
      now = now.add(const Duration(seconds: 10));
      await c.step(1);
      final events = await store.events(since: DateTime(2000));
      expect(events.last.titleId, 't2');
      expect(events.last.action, ReelAction.sampled.name);
      expect(events.last.seconds, 10);
      c.dispose();
    });

    test('a phone player that broke records nothing about the title', () async {
      final c = make(externalClips: true, clock: clock);
      await c.start();
      c.clipStarted('t1');
      c.clipFailed('t1');
      now = now.add(const Duration(milliseconds: 300));
      await c.step(1);
      expect(await actions(), [ReelAction.unplayed.name]);
      c.dispose();
    });
  });
}
