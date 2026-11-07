// The fake engine's controllers are closed with the test.
// ignore_for_file: close_sinks
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/reel/reel_keys.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_clip_cache.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';

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
  final reads = <String>[];

  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async {
    reads.add(ratingKey);
    return MediaItem(
      id: ratingKey,
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Harbor Lights $ratingKey',
      serverId: serverId,
    );
  }

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) => item(serverId, ratingKey);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

/// A deck with an intro card once it has loaded (like New this week), and
/// a build that can land later.
class _IntroDeck extends ReelDeck {
  _IntroDeck(this.id, this.cards, {this.line = '2 films, 1 show arrived. 3 worth a look.'});

  @override
  final String id;
  List<ReelCardData> cards;
  String? line;

  @override
  String get name => 'Deck $id';
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;

  @override
  final ValueNotifier<int> rebuilt = ValueNotifier(0);

  ReelDeckIntro? _intro;

  @override
  ReelDeckIntro? get intro => _intro;

  @override
  Future<List<ReelCardData>> load() async {
    final l = line;
    _intro = l == null || cards.isEmpty ? null : ReelDeckIntro(line: l);
    return cards;
  }

  void land(List<ReelCardData> next) {
    cards = next;
    rebuilt.value++;
  }
}

class _Deck extends _IntroDeck {
  _Deck(super.id, super.cards) : super(line: null);
}

ReelCardData _card(String id) => ReelCardData(
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
  best: IndexedTitle(
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
  ),
);

String _clip(String id) => 'https://s1.example/services/iva/assets/$id/video.mp4';

List<String> _pages(ReelController c) => [
  for (var i = 0; i < c.slotCount; i++)
    switch (c.slotAt(i)) {
      ReelSlot(kind: ReelSlotKind.card, :final card?) => card.id,
      ReelSlot(:final kind) => kind.name,
    },
];

void main() {
  late ForkDatabase db;
  late ReelStore store;
  FakeClipEngine? engine;

  ReelController make(
    List<ReelDeck> decks, {
    bool externalClips = false,
    ReelMedia? media,
    ReelClipEnd Function()? clipEnd,
  }) => ReelController(
    decks: decks,
    resolver: ClipResolver(
      servers: _Servers(),
      store: store,
      aniList: (_) async => null,
      animeThemes: (_) async => const {},
    ),
    clips: ClipPlayer(engine: () => engine = FakeClipEngine()),
    store: store,
    media: media ?? _Media(),
    onWatch: (_, {required onTv}) async => false,
    addToWatchlist: (_) async => true,
    externalClips: externalClips,
    clipEnd: clipEnd,
    clipCache: ReelClipCache(supported: false),
  );

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    engine = null;
  });

  tearDown(() async => db.close());

  test('TV: a deck with an intro opens on it, nothing plays, and its first card is the one preloaded', () async {
    MemoryLogOutput.clearLogs();
    final media = _Media();
    final c = make([
      _IntroDeck('a', [_card('1'), _card('2'), _card('3')]),
    ], media: media);
    await c.start();
    await pumpEventQueue();
    expect(_pages(c), ['intro', 't1', 't2', 't3', 'poolEnd']);
    expect(c.current.kind, ReelSlotKind.intro);
    expect(c.current.intro?.line, '2 films, 1 show arrived. 3 worth a look.');
    expect(c.current.card, isNull);
    expect((c.page, c.index), (0, 0));
    expect(engine?.calls.where((x) => x.startsWith('open')) ?? const [], isEmpty, reason: 'nothing plays');
    expect(c.clips.preloaded, {ClipPreloadRank.next: _clip('1'), ClipPreloadRank.ahead: _clip('2')});
    expect(media.reads, containsAll(['1', '2']), reason: "the window's metadata: the first card and the next");
    expect(media.reads, isNot(contains('3')), reason: 'no read past two ahead (D15)');
    expect(c.current.previews.map((p) => p.card.id), ['t1', 't2', 't3']);
    expect(c.current.previews.map((p) => p.item?.id), ['1', '2', null]);
    expect(MemoryLogOutput.getLogs().map((l) => l.message), contains('[ReelIntro] a: intro shown, 3 cards after it'));

    await c.step(1);
    expect(c.current.card?.id, 't1');
    expect((c.page, c.index), (1, 0));
    expect(engine!.calls, contains('open ${_clip('1')}'));
    await c.step(1);
    expect(c.current.card?.id, 't2');
    await c.step(-1);
    await c.step(-1);
    expect(c.current.kind, ReelSlotKind.intro, reason: 'back from the first card is the intro');
    await c.step(-1);
    expect(c.current.kind, ReelSlotKind.intro, reason: 'nothing before it');
    c.dispose();
  });

  test('a deck with no intro opens on its first card, pages as before', () async {
    final c = make([
      _Deck('a', [_card('1'), _card('2')]),
    ]);
    await c.start();
    expect(_pages(c), ['t1', 't2', 'poolEnd']);
    expect(c.current.card?.id, 't1');
    expect(c.page, 0);
    c.dispose();
  });

  test('the intro comes up once a session: coming back carries on at the card', () async {
    final c = make([
      _IntroDeck('a', [_card('1'), _card('2'), _card('3')]),
      _Deck('b', [_card('8')]),
    ]);
    await c.start();
    expect(c.current.kind, ReelSlotKind.intro);
    await c.step(1);
    await c.suspend();
    await c.start();
    expect(c.current.card?.id, 't1', reason: 'the card it was on, not the intro again');
    await c.switchDeck(1);
    expect(c.current.card?.id, 't8');
    await c.switchDeck(1);
    expect(c.current.card?.id, 't1', reason: "the deck's own cursor");
    c.dispose();
  });

  test('a deck switched to for the first time opens on its intro; On TV mode opens on the card asked for', () async {
    final c = make([
      _Deck('b', [_card('8')]),
      _IntroDeck('a', [_card('1'), _card('2')]),
      _IntroDeck('n', [_card('4'), _card('5')]),
    ]);
    await c.start();
    await c.switchDeck(1);
    expect(c.deck.id, 'a');
    expect(c.current.kind, ReelSlotKind.intro);
    await c.openAt('n', 'g4');
    expect(c.deck.id, 'n');
    expect(c.current.card?.id, 't4', reason: 'the phone asked for this card: it opens, not the intro');
    expect(c.page, 1);
    c.dispose();
  });

  test('a deck that was empty takes its list with the intro first when the build lands', () async {
    final deck = _IntroDeck('a', []);
    final c = make([deck]);
    await c.start();
    expect(c.current.kind, ReelSlotKind.empty);
    deck.land([_card('1'), _card('2')]);
    await pumpEventQueue();
    expect(c.current.kind, ReelSlotKind.intro);
    expect(_pages(c), ['intro', 't1', 't2', 'poolEnd']);
    c.dispose();
  });

  test('the phone remote hears the intro line', () async {
    final c = make([
      _IntroDeck('a', [_card('1')]),
    ]);
    await c.start();
    final state = c.remoteState();
    expect(state['intro'], {'line': '2 films, 1 show arrived. 3 worth a look.'});
    expect(state['card'], isNull);
    expect(state['poolEnd'], isFalse);
    await c.step(1);
    expect(c.remoteState().containsKey('intro'), isFalse);
    c.dispose();
  });

  test('phone: the intro is page 0 of the feed and a swipe lands on the first card', () async {
    final c = make([
      _IntroDeck('a', [_card('1'), _card('2')]),
    ], externalClips: true);
    await c.start();
    expect(c.page, 0);
    expect(c.slotCount, 4);
    expect(c.slotAt(1).card?.id, 't1');
    await c.step(1);
    expect((c.page, c.index), (1, 0));
    expect(c.current.card?.id, 't1');
    c.dispose();
  });

  test('OK on the intro starts the deck; on a card it still follows the pref', () {
    expect(
      reelOkTarget(phase: ClipPhase.idle, kind: ReelSlotKind.intro, okAction: ReelOkAction.watch),
      ReelOkTarget.start,
    );
    expect(
      reelOkTarget(phase: ClipPhase.idle, kind: ReelSlotKind.card, okAction: ReelOkAction.watch),
      ReelOkTarget.watch,
    );
  });

  test('TV, Next card: the intro moves on to the first card while someone is there', () {
    fakeAsync((async) {
      final c = make([
        _IntroDeck('a', [_card('1'), _card('2')]),
      ], clipEnd: () => ReelClipEnd.nextCard);
      unawaited(c.start());
      async.flushMicrotasks();
      expect(c.current.kind, ReelSlotKind.intro);
      async.elapse(ReelController.introHold - const Duration(seconds: 1));
      expect(c.current.kind, ReelSlotKind.intro);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(c.current.card?.id, 't1');
      c.dispose();
    });
  });

  test('TV, Twice then hold: the intro waits for a key', () {
    fakeAsync((async) {
      final c = make([
        _IntroDeck('a', [_card('1')]),
      ], clipEnd: () => ReelClipEnd.twiceThenHold);
      unawaited(c.start());
      async.flushMicrotasks();
      async.elapse(ReelController.introHold * 2);
      async.flushMicrotasks();
      expect(c.current.kind, ReelSlotKind.intro);
      c.dispose();
    });
  });
}
