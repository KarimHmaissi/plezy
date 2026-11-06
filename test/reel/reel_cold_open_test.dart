// The fake engines' controllers are left open; each test's engines go with it.
// ignore_for_file: close_sinks
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_cursor.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_head.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/settings_service.dart' show ReelCellular;
import 'package:plezy/utils/app_logger.dart';

import 'clip_player_test.dart' show FakeClipEngine;

/// The Reel's cold open (plan V2-04): the clip core warmed alongside the
/// deck, decks that show their first cards before the rest, the card the
/// Reel was left on opened at once, and the saved answers added after the
/// first card.

/// One trailer per title, except the titles in [bare] (AI cards).
class _Servers implements ReelServers {
  _Servers([this.bare = const {}]);

  final Set<String> bare;

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async =>
      bare.contains(ratingKey)
      ? const []
      : [
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

String _clip(String id) => 'https://s1.example/services/iva/assets/$id/video.mp4';

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async => MediaItem(
    id: ratingKey,
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Harbor Lights $ratingKey',
    serverId: serverId,
  );

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) => item(serverId, ratingKey);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

IndexedTitle _copy(String id) => IndexedTitle(
  id: 's1:$id',
  serverId: 's1',
  serverName: 'Server A',
  libraryKey: '1',
  libraryTitle: 'Films',
  ratingKey: id,
  type: 'movie',
  title: 'Harbor Lights $id',
  genres: '',
  countries: '',
  directors: '',
  writers: '',
  cast: '',
  collections: '',
  groupKey: 'g$id',
  summary: '',
);

ReelCardData _card(String id, {String? chip}) => ReelCardData(
  title: ReelTitle(
    titleId: 't$id',
    groupKey: 'g$id',
    title: 'Harbor Lights $id',
    isShow: false,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: 't$id', groupKey: 'g$id'),
    seen: SeenState.unseen,
  ),
  best: _copy(id),
  chip: chip,
);

List<ReelCardData> _cards(List<String> ids) => [for (final id in ids) _card(id)];

/// A deck whose load can wait on [gate].
class _Deck extends ReelDeck {
  _Deck(this.id, this.cards, {this.isDaily = false});

  @override
  final String id;
  List<ReelCardData> cards;
  final bool isDaily;
  Completer<void>? gate;
  int loads = 0;

  @override
  String get name => 'Deck $id';
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;
  @override
  bool get daily => isDaily;

  @override
  Future<List<ReelCardData>> load() async {
    loads++;
    await gate?.future;
    return cards;
  }
}

/// A deck that gives its first [headCount] cards, then the rest
/// ([restCards], else the cards after the head) when asked, held by
/// [restGate] and failing [failRests] times.
class _PartsDeck extends _Deck {
  _PartsDeck(super.id, super.cards);

  static const int headCount = 3;
  List<ReelCardData>? headCards;
  List<ReelCardData>? restCards;
  Completer<void>? restGate;
  int failRests = 0;
  int restCalls = 0;
  final asked = <int>[];

  @override
  final ValueNotifier<int> rebuilt = ValueNotifier(0);

  @override
  Future<ReelDeckParts> loadParts(int head) async {
    asked.add(head);
    loads++;
    await gate?.future;
    final more = restCards ?? cards.sublist(headCount);
    return ReelDeckParts(headCards ?? cards.take(headCount).toList(), () async {
      restCalls++;
      await restGate?.future;
      if (failRests > 0) {
        failRests--;
        throw StateError('server unreachable');
      }
      return more;
    });
  }
}

List<String> _log(String prefix) =>
    MemoryLogOutput.getLogs().map((e) => e.message).where((m) => m.startsWith(prefix)).toList().reversed.toList();

void main() {
  late ForkDatabase db;
  late ReelStore store;
  late List<FakeClipEngine> engines;
  late List<String> headAsked;

  Future<ReelCardData?> headCard(DeckEntry e) async {
    headAsked.add(e.ratingKey!);
    return _card(e.ratingKey!, chip: e.chip);
  }

  ReelController make({
    List<ReelDeck>? decks,
    bool warm = false,
    ReelHeadCard? head,
    Future<List<ReelDeck>> Function()? moreDecks,
    bool externalClips = false,
    DateTime Function()? clock,
    ReelServers? servers,
    ReelCellular Function()? cellular,
    bool Function()? metered,
    ReelWatch? onWatch,
    Future<ReelDeck?> Function(String id)? deckFor,
    bool keepCursor = false,
  }) => ReelController(
    decks:
        decks ??
        [
          _Deck('a', _cards(['1', '2', '3'])),
        ],
    resolver: ClipResolver(
      servers: servers ?? _Servers(),
      store: store,
      aniList: (_) async => null,
      animeThemes: (_) async => const {},
    ),
    clips: ClipPlayer(
      engine: () {
        final e = FakeClipEngine();
        engines.add(e);
        return e;
      },
    ),
    store: store,
    media: _Media(),
    onWatch: onWatch ?? (_, {required onTv}) async => false,
    addToWatchlist: (_) async => true,
    externalClips: externalClips,
    warmClipCore: warm,
    headCard: head,
    moreDecks: moreDecks,
    clock: clock,
    cellular: cellular,
    metered: metered,
    deckFor: deckFor,
    keepCursor: keepCursor,
  );

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    engines = [];
    headAsked = [];
    MemoryLogOutput.clearLogs();
  });

  tearDown(() async => db.close());

  group('warm core', () {
    test('TV: the clip core is warmed while the deck loads, and the first clip opens on it', () async {
      final deck = _Deck('a', _cards(['1', '2']))..gate = Completer<void>();
      final c = make(decks: [deck], warm: true);
      final start = c.start();
      await pumpEventQueue();
      expect(engines, hasLength(1), reason: 'built before the deck has landed');
      expect(engines.single.calls, ['warm'], reason: 'no media: nothing takes a decoder before an open');
      expect(c.current.kind, ReelSlotKind.loading);

      deck.gate!.complete();
      await start;
      expect(engines, hasLength(1), reason: 'the open reuses the warm core');
      expect(engines.single.calls.where((x) => x.startsWith('open')), ['open ${_clip('1')}']);
      expect(_log('[ReelStart] #1 warm core='), hasLength(1));
      c.dispose();
    });

    test('no warm without the flag, on the phone, under memory pressure or with stills only', () async {
      Future<int> enginesAtStart(ReelController c, _Deck deck, {Future<void> Function()? before}) async {
        engines.clear();
        await before?.call();
        final start = c.start();
        await pumpEventQueue();
        final n = engines.length;
        deck.gate!.complete();
        await start;
        c.dispose();
        return n;
      }

      _Deck gated() => _Deck('a', _cards(['1']))..gate = Completer<void>();

      var d = gated();
      expect(await enginesAtStart(make(decks: [d]), d), 0, reason: 'off by default: the first open builds it');
      d = gated();
      expect(await enginesAtStart(make(decks: [d], warm: true, externalClips: true), d), 0);
      d = gated();
      final low = make(decks: [d], warm: true);
      expect(await enginesAtStart(low, d, before: low.trimMemory), 0);
      d = gated();
      expect(
        await enginesAtStart(
          make(decks: [d], warm: true, cellular: () => ReelCellular.stillsOnly, metered: () => true),
          d,
        ),
        0,
      );
    });

    test('a start after a Watch warms the core again, after the hand-over let it go', () async {
      final c = make(warm: true, onWatch: (_, {required onTv}) async => true);
      await c.start();
      expect(await c.watch(), isTrue);
      expect(engines.single.disposed, isTrue);
      await c.start();
      expect(engines, hasLength(2));
      expect(engines.last.calls.first, 'warm');
      c.dispose();
    });
  });

  group('first cards first', () {
    test('the first cards show before the rest of the deck has loaded; the rest follows them', () async {
      final deck = _PartsDeck('p', _cards(['1', '2', '3', '4', '5', '6']))..restGate = Completer<void>();
      final c = make(decks: [deck]);
      await c.start();
      expect(deck.asked, [ReelDeck.headEntries]);
      expect(c.cards!.map((x) => x.id), ['t1', 't2', 't3']);
      expect(c.current.card!.id, 't1');
      expect(engines.single.calls, contains('open ${_clip('1')}'));
      expect(_log('[ReelDeck] p: 3 cards').single, contains('the rest to follow'));

      deck.restGate!.complete();
      await pumpEventQueue();
      expect(c.cards!.map((x) => x.id), ['t1', 't2', 't3', 't4', 't5', 't6']);
      expect(c.index, 0, reason: 'the cursor stays');
      expect(c.current.card!.id, 't1');
      expect(_log('[ReelDeck] p: +3 cards after the first'), hasLength(1));
      c.dispose();
    });

    test('titles already in the list are left out of the rest', () async {
      final deck = _PartsDeck('p', _cards(['1', '2', '3']))..restCards = _cards(['2', '4', '3', '5']);
      final c = make(decks: [deck]);
      await c.start();
      await pumpEventQueue();
      expect(c.cards!.map((x) => x.id), ['t1', 't2', 't3', 't4', 't5']);
      c.dispose();
    });

    test('at the end of the first cards when the rest lands, the first new card shows', () async {
      final deck = _PartsDeck('p', _cards(['1', '2', '3', '4']))..restGate = Completer<void>();
      final c = make(decks: [deck]);
      await c.start();
      for (var i = 0; i < 3; i++) {
        await c.step(1);
      }
      expect(c.current.kind, ReelSlotKind.loading, reason: "the rest is on its way: not the deck's end");
      deck.restGate!.complete();
      await pumpEventQueue();
      expect(c.current.card!.id, 't4');
      expect(engines.last.calls.last, 'open ${_clip('4')}');
      c.dispose();
    });

    test("first entries that leave no card: the rest loads first, and the deck never shows as empty", () async {
      final deck = _PartsDeck('p', _cards(['1', '2', '3', '4', '5']))
        ..headCards = const []
        ..restCards = _cards(['4', '5']);
      final c = make(decks: [deck]);
      final kinds = <ReelSlotKind>[];
      c.addListener(() {
        if (c.cards != null) kinds.add(c.current.kind);
      });
      await c.start();
      expect(deck.restCalls, 1);
      expect(c.cards!.map((x) => x.id), ['t4', 't5']);
      expect(c.current.card!.id, 't4');
      expect(kinds, isNot(contains(ReelSlotKind.empty)));
      expect(_log('[ReelDeck] p: +'), isEmpty, reason: 'loaded whole, nothing follows');
      c.dispose();
    });

    test("a rest that failed leaves the deck's end showing until it is asked again", () async {
      final deck = _PartsDeck('p', _cards(['1', '2', '3', '4']))..failRests = 1;
      final c = make(decks: [deck]);
      await c.start();
      await pumpEventQueue();
      expect(c.slotAt(3).kind, ReelSlotKind.poolEnd);
      c.dispose();
    });

    test('a rest that failed is asked again when the cursor reaches the end', () async {
      final deck = _PartsDeck('p', _cards(['1', '2', '3', '4', '5']))..failRests = 1;
      final c = make(decks: [deck]);
      await c.start();
      await pumpEventQueue();
      expect(deck.restCalls, 1);
      expect(c.cards, hasLength(3));
      await c.step(1);
      await c.step(1);
      expect(deck.restCalls, 1, reason: 'not before the end');
      await c.step(1);
      await pumpEventQueue();
      expect(deck.restCalls, 2);
      expect(c.cards!.map((x) => x.id), ['t1', 't2', 't3', 't4', 't5']);
      expect(c.current.card!.id, 't4');
      c.dispose();
    });

    test("a fresh build that lands first replaces the list: the old rest isn't appended", () async {
      final deck = _PartsDeck('p', _cards(['1', '2', '3', '4', '5']))..restGate = Completer<void>();
      final c = make(decks: [deck]);
      await c.start();
      deck.cards = _cards(['7', '8']);
      deck.rebuilt.value++;
      await pumpEventQueue();
      expect(c.cards!.map((x) => x.id), ['t1', 't7', 't8']);
      deck.restGate!.complete();
      await pumpEventQueue();
      expect(c.cards!.map((x) => x.id), ['t1', 't7', 't8']);
      c.dispose();
    });

    test("On TV mode's card past the first ones: the start waits for the rest and lands on it", () async {
      final deck = _PartsDeck('p', _cards(['1', '2', '3', '4', '5']))..restGate = Completer<void>();
      final c = make(
        decks: [
          _Deck('a', _cards(['9'])),
          deck,
        ],
      );
      var done = false;
      final start = c.start(deckId: 'p', groupKey: 'g5').then((_) => done = true);
      await pumpEventQueue();
      expect(done, isFalse);
      deck.restGate!.complete();
      await start;
      expect(c.deck.id, 'p');
      expect(c.current.card!.id, 't5');
      c.dispose();
    });

    test("Tonight's picks waits at the end only once the deck's list is whole", () async {
      final deck = _PartsDeck('p', _cards(['1', '2', '3', '4']))..restGate = Completer<void>();
      final c = make(decks: [deck]);
      await c.start();
      await c.save();
      expect(c.slotCount, 4, reason: 'three cards and the end: no decision card yet');
      deck.restGate!.complete();
      await pumpEventQueue();
      expect(c.slotCount, 6, reason: 'four cards, the decision card and the end');
      c.dispose();
    });
  });

  group('the card the Reel was left on', () {
    Future<void> leaveOnCard2({DateTime Function()? clock}) async {
      final c = make(head: headCard, clock: clock);
      await c.start();
      await c.step(1);
      await c.suspend();
      c.dispose();
      MemoryLogOutput.clearLogs();
    }

    test('a suspend keeps the card on screen; a cold start opens it at once and the deck follows it', () async {
      await leaveOnCard2();
      final kept = ReelHead.decode(await store.cached(ReelStore.headKey('a')));
      expect(kept?.titleId, 't2');
      engines.clear();

      final deck = _Deck('a', _cards(['1', '2', '3']))..gate = Completer<void>();
      final c = make(decks: [deck], head: headCard, warm: true);
      await c.start();
      expect(headAsked, ['2']);
      expect(deck.loads, 1, reason: "the deck's own load started first");
      expect(c.cards!.map((x) => x.id), ['t2']);
      expect(c.current.card!.id, 't2');
      expect(engines.single.calls, containsAllInOrder(['warm', 'open ${_clip('2')}']));
      expect(_log('[ReelStart] #1 head replay deck=a'), hasLength(1));

      deck.gate!.complete();
      await pumpEventQueue();
      expect(c.cards!.map((x) => x.id), ['t2', 't1', 't3']);
      expect(c.index, 0);
      expect(c.current.card!.id, 't2');

      engines.single.firstFrameCtl.add(null);
      final spans = _log('[ReelStart] #1 spans').single;
      expect(spans, matches(RegExp(r'^\[ReelStart\] #1 spans playing prefs=\d+ms deck=\d+ms load=\d+ms ')));
      expect(spans, contains('head=replay'));
      expect(spans, matches(RegExp(r'total=\d+ms$')));
      c.dispose();
    });

    test("a card resting after Not for me isn't replayed", () async {
      await leaveOnCard2();
      await store.notForMe('t2');
      final deck = _Deck('a', _cards(['1', '2', '3']))..gate = Completer<void>();
      final c = make(decks: [deck], head: headCard);
      final start = c.start();
      await pumpEventQueue();
      expect(c.current.kind, ReelSlotKind.loading);
      deck.gate!.complete();
      await start;
      expect(c.current.card!.id, 't1');
      expect(_log('[ReelStart] #1 head none'), hasLength(1));
      c.dispose();
    });

    test("a daily deck's card kept on another day isn't replayed", () async {
      final c1 = make(
        decks: [
          _Deck('d', _cards(['1', '2']), isDaily: true),
        ],
        head: headCard,
        clock: () => DateTime(2026, 3, 9, 22),
      );
      await c1.start();
      await c1.step(1);
      await c1.suspend();
      c1.dispose();
      expect(await store.cached(ReelStore.headKey('d')), isNotNull);

      final deck = _Deck('d', _cards(['1', '2']), isDaily: true)..gate = Completer<void>();
      final c = make(decks: [deck], head: headCard, clock: () => DateTime(2026, 3, 10, 9));
      final start = c.start();
      await pumpEventQueue();
      expect(c.current.kind, ReelSlotKind.loading);
      deck.gate!.complete();
      await start;
      expect(c.current.card!.id, 't1');
      c.dispose();
    });

    test('leaving on an AI card forgets the kept card; a warm controller replays nothing', () async {
      final c = make(
        decks: [
          _Deck('a', _cards(['5', '6'])),
        ],
        head: headCard,
        servers: _Servers({'5'}),
      );
      await c.start();
      expect(c.current.isAiCard, isTrue);
      // An older card kept for the deck goes with the suspend.
      await store.cache(
        ReelStore.headKey('a'),
        ReelHead.of(_card('6'), day: 'pool:2026-03-10', at: DateTime.now()).encode(),
      );
      await c.suspend();
      expect(await store.cached(ReelStore.headKey('a')), isNull);

      // Back to the same controller: its deck is loaded, so the card at its
      // cursor shows, with no head card read.
      headAsked.clear();
      await c.start();
      expect(headAsked, isEmpty);
      c.dispose();
    });

    test('Watch keeps the card it leaves from', () async {
      final c = make(head: headCard, onWatch: (_, {required onTv}) async => true);
      await c.start();
      await c.watch();
      await pumpEventQueue();
      expect(ReelHead.decode(await store.cached(ReelStore.headKey('a')))?.titleId, 't1');
      c.dispose();
    });

    test('the phone neither keeps nor replays a card', () async {
      final c = make(head: headCard, externalClips: true);
      await c.start();
      await c.step(1);
      await c.suspend();
      c.dispose();
      expect(await store.cached(ReelStore.headKey('a')), isNull);
      expect(headAsked, isEmpty);
    });

    test('the kept row round-trips, and a row not shaped as written reads as none', () {
      final head = ReelHead.of(
        _card('4', chip: '#2 this week'),
        day: 'pool:2026-03-10',
        at: DateTime(2026, 3, 10, 21),
      );
      final back = ReelHead.decode(head.encode())!;
      expect(back.titleId, 't4');
      expect(back.entry.rowId, 's1:4');
      expect(back.entry.chip, '#2 this week');
      expect(back.entry.isShow, isFalse);
      expect(back.day, 'pool:2026-03-10');
      expect(back.at, DateTime(2026, 3, 10, 21));
      expect(ReelHead.decode(''), isNull);
      expect(ReelHead.decode('{"id":"t4"}'), isNull);
      expect(ReelHead.decode('not json'), isNull);
    });
  });

  group('answer decks after the first card', () {
    test('added once the first card shows, never before, once, and without repeating a deck', () async {
      var asked = 0;
      final c = make(
        moreDecks: () async {
          asked++;
          return [
            _Deck('ai:x', _cards(['9'])),
            _Deck('a', _cards(['8'])),
          ];
        },
      );
      await c.start();
      await pumpEventQueue();
      expect(asked, 0, reason: 'the first clip has no frame yet');
      expect(c.decks.map((d) => d.id), ['a']);

      engines.single.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(asked, 1);
      expect(c.decks.map((d) => d.id), ['a', 'ai:x']);
      expect(_log('[ReelDeck] 1 answer decks added'), hasLength(1));

      await c.step(1);
      engines.single.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(asked, 1);
      c.dispose();
    });

    test('a deck opened by id first is not added again; a still card counts as shown', () async {
      final c = make(
        servers: _Servers({'9'}),
        deckFor: (id) async => _Deck(id, _cards(['9'])),
        moreDecks: () async => [
          _Deck('ai:x', _cards(['7'])),
          _Deck('ai:y', _cards(['6'])),
        ],
      );
      await c.start(deckId: 'ai:x');
      await pumpEventQueue();
      expect(c.current.isAiCard, isTrue);
      expect(c.decks.map((d) => d.id), ['a', 'ai:x', 'ai:y']);
      c.dispose();
    });
  });

  group('the cursor kept per deck and day (V2-14)', () {
    final day1 = DateTime(2026, 3, 10, 21);

    Future<ReelCursor?> keptFor(String deck, [DateTime? at]) async =>
        ReelCursor.decode(await store.cached(ReelStore.cursorKey(deck, at ?? day1)));

    /// A session on deck 'a' (cards 1-5) that steps [steps] times and is
    /// left; its cursor writes are waited for.
    Future<void> leaveAfter(int steps, {DateTime? at, bool daily = false}) async {
      final c = make(
        decks: [
          _Deck('a', _cards(['1', '2', '3', '4', '5']), isDaily: daily),
        ],
        keepCursor: true,
        clock: () => at ?? day1,
      );
      await c.start();
      for (var i = 0; i < steps; i++) {
        await c.step(1);
      }
      await c.suspend();
      await c.cursorWritten;
      c.dispose();
      MemoryLogOutput.clearLogs();
    }

    test('every card change keeps the cursor; the next session carries on from it', () async {
      await leaveAfter(2);
      final kept = await keptFor('a');
      expect(kept?.id, 't3');
      expect(kept?.after, 't4');

      final c = make(
        decks: [
          _Deck('a', _cards(['1', '2', '3', '4', '5'])),
        ],
        keepCursor: true,
        clock: () => day1,
      );
      await c.start();
      expect(c.index, 2);
      expect(c.current.card!.id, 't3');
      expect(engines.last.calls.where((x) => x.startsWith('open')), ['open ${_clip('3')}']);
      expect(_log('[ReelDeck] a: carries on at card 2 of 5'), hasLength(1));
      await c.step(1);
      expect(c.current.card!.id, 't4');
      c.dispose();
    });

    test('a held key: five quick steps keep the card they land on', () async {
      final c = make(
        decks: [
          _Deck('a', _cards(['1', '2', '3', '4', '5', '6', '7'])),
        ],
        keepCursor: true,
        clock: () => day1,
      );
      await c.start();
      await c.cursorWritten;
      final steps = [for (var i = 0; i < 5; i++) c.step(1)];
      await Future.wait(steps);
      await c.cursorWritten;
      expect((await keptFor('a'))?.id, 't6');
      c.dispose();
    });

    test('the card left the list (Not for me): the next one is where it carries on', () async {
      await leaveAfter(2);
      await store.notForMe('t3');
      final c = make(
        decks: [
          _Deck('a', _cards(['1', '2', '3', '4', '5'])),
        ],
        keepCursor: true,
        clock: () => day1,
      );
      await c.start();
      expect(c.current.card!.id, 't4');
      c.dispose();
    });

    test("the end of the deck is kept as the end; a daily deck doesn't carry yesterday's cursor", () async {
      await leaveAfter(5, daily: true);
      expect((await keptFor('a'))?.past, isTrue);
      final c = make(
        decks: [
          _Deck('a', _cards(['1', '2', '3', '4', '5']), isDaily: true),
        ],
        keepCursor: true,
        clock: () => day1,
      );
      await c.start();
      expect(c.current.kind, ReelSlotKind.poolEnd);
      c.dispose();

      final next = make(
        decks: [
          _Deck('a', _cards(['1', '2', '3', '4', '5']), isDaily: true),
        ],
        keepCursor: true,
        clock: () => day1.add(const Duration(days: 1)),
      );
      await next.start();
      expect(next.current.card!.id, 't1');
      next.dispose();
    });

    test("another deck carries yesterday's cursor on", () async {
      await leaveAfter(1);
      final c = make(
        decks: [
          _Deck('a', _cards(['1', '2', '3', '4', '5'])),
        ],
        keepCursor: true,
        clock: () => day1.add(const Duration(days: 1)),
      );
      await c.start();
      expect(c.current.card!.id, 't2');
      c.dispose();
    });

    test('a cursor past the first cards: the rest is loaded before the first card shows', () async {
      await leaveAfter(4);
      final deck = _PartsDeck('a', _cards(['1', '2', '3', '4', '5']));
      final c = make(decks: [deck], keepCursor: true, clock: () => day1);
      await c.start();
      expect(deck.restCalls, 1);
      expect(c.cards!.map((x) => x.id), ['t1', 't2', 't3', 't4', 't5']);
      expect(c.current.card!.id, 't5');
      expect(engines.last.calls.where((x) => x.startsWith('open')), ['open ${_clip('5')}'], reason: 'no card 1 first');
      c.dispose();
    });

    test('a cursor within the first cards waits for nothing more', () async {
      await leaveAfter(1);
      final deck = _PartsDeck('a', _cards(['1', '2', '3', '4', '5']))..restGate = Completer<void>();
      final c = make(decks: [deck], keepCursor: true, clock: () => day1);
      await c.start();
      expect(c.current.card!.id, 't2');
      deck.restGate!.complete();
      await pumpEventQueue();
      expect(c.cards, hasLength(5));
      expect(c.current.card!.id, 't2');
      c.dispose();
    });

    test('TV: a replayed head card takes its own place when the list lands, so the cards after it come next', () async {
      final first = make(head: headCard, keepCursor: true, clock: () => day1);
      await first.start();
      await first.step(1);
      await first.suspend();
      await first.cursorWritten;
      first.dispose();

      final deck = _Deck('a', _cards(['1', '2', '3']))..gate = Completer<void>();
      final c = make(decks: [deck], head: headCard, keepCursor: true, clock: () => day1);
      await c.start();
      expect(c.cards!.map((x) => x.id), ['t2']);
      deck.gate!.complete();
      await pumpEventQueue();
      expect(c.cards!.map((x) => x.id), ['t1', 't2', 't3']);
      expect(c.index, 1);
      expect(c.current.card!.id, 't2');
      expect(_log('[ReelDeck] a: the replayed card is card 1 of 3'), hasLength(1));
      await c.step(1);
      expect(c.current.card!.id, 't3');
      c.dispose();
    });

    test('off: nothing is kept and every load starts on the first card', () async {
      final c = make(
        decks: [
          _Deck('a', _cards(['1', '2', '3'])),
        ],
        clock: () => day1,
      );
      await c.start();
      await c.step(1);
      await c.cursorWritten;
      expect(await keptFor('a'), isNull);
      c.dispose();
    });

    test('the kept row round-trips and lands by id, then by the card after it', () {
      final list = _cards(['1', '2', '3']);
      expect(ReelCursor.at(list, 1)?.encode(), '{"id":"t2","after":"t3"}');
      expect(ReelCursor.at(list, 3)?.past, isTrue);
      expect(ReelCursor.at(const [], 0), isNull);
      final back = ReelCursor.decode(ReelCursor.at(list, 1)!.encode())!;
      expect(back.seekIn(list), 1);
      expect(back.seekIn(_cards(['3', '1'])), 0, reason: 't2 gone: on t3');
      expect(back.seekIn(_cards(['7'])), isNull);
      expect(ReelCursor.decode(ReelCursor.at(list, 3)!.encode())!.seekIn(list), 3);
      expect(ReelCursor.decode(''), isNull);
      expect(ReelCursor.decode('{"after":"t3"}'), isNull);
      expect(ReelCursor.decode('not json'), isNull);
    });
  });
}
