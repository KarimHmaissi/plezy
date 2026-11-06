// The fake engine's controllers are closed in tearDown.
// ignore_for_file: close_sinks
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/reel/reel_held_step.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/customisation/mirror_store.dart';
import 'package:plezy/services/memory_trim_policy.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_data_budget.dart';
import 'package:plezy/services/reel/reel_deck_prefs.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_playback_profile.dart';
import 'package:plezy/services/reel/reel_prefetcher.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';
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

/// Two trailers per title, on servers that can be taken offline.
class _FlakyServers implements ReelServers {
  final Set<String> offline = {};
  int reads = 0;

  PlexExtraClip _x(String rk, String title, int i) => PlexExtraClip(
    ratingKey: rk,
    title: title,
    partKey: '/services/iva/assets/$rk/video.mp4',
    subtype: 'trailer',
    index: i,
  );

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    if (offline.contains(serverId)) throw ReelServerUnavailable(serverId);
    reads++;
    return [_x('a$ratingKey', 'Official Trailer', 0), _x('b$ratingKey', 'Trailer 2', 1)];
  }

  @override
  String? clipUrl(String serverId, String partKey) =>
      offline.contains(serverId) ? null : 'https://$serverId.example$partKey';
}

/// No trailer for [none]: those cards resolve to AI cards.
class _SomeServers extends _Servers {
  _SomeServers(this.none);

  final Set<String> none;

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async =>
      none.contains(ratingKey) ? const [] : super.extras(serverId, ratingKey, timeout: timeout);
}

class _Media implements ReelMedia {
  int fullReads = 0;

  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async => MediaItem(
    id: ratingKey,
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Title $ratingKey',
    serverId: serverId,
  );

  /// The full read: tells itself apart from the card's (lean) item.
  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) async {
    fullReads++;
    return MediaItem(
      id: ratingKey,
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Full $ratingKey',
      serverId: serverId,
    );
  }

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

/// Metadata for one card that lands only when the test says so.
class _GatedMedia extends _Media {
  _GatedMedia(this.gated);

  final String gated;
  final gate = Completer<void>();

  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async {
    if (ratingKey == gated) await gate.future;
    return super.item(serverId, ratingKey);
  }
}

/// A full read that fails (the server went away before Watch).
class _NoFullMedia extends _Media {
  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) async => throw StateError('offline');
}

/// Counts metadata reads.
class _CountingMedia extends _Media {
  _CountingMedia(this.onRead);

  final void Function() onRead;

  @override
  Future<MediaItem?> item(String serverId, String ratingKey) {
    onRead();
    return super.item(serverId, ratingKey);
  }
}

/// One card's extras that answer only when the test says so.
class _GatedServers extends _Servers {
  _GatedServers(this.gated);

  final String gated;
  final gate = Completer<void>();

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    if (ratingKey == gated) await gate.future;
    return super.extras(serverId, ratingKey, timeout: timeout);
  }
}

/// Records which cards' extras and metadata were read, in order; one
/// card's extras can be held until the test says.
class _RecordingServers extends _Servers {
  _RecordingServers({this.gated});

  final String? gated;
  final gate = Completer<void>();
  final reads = <String>[];

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    reads.add(ratingKey);
    if (ratingKey == gated) await gate.future;
    return super.extras(serverId, ratingKey, timeout: timeout);
  }
}

class _RecordingMedia extends _Media {
  final reads = <String>[];

  @override
  Future<MediaItem?> item(String serverId, String ratingKey) {
    reads.add(ratingKey);
    return super.item(serverId, ratingKey);
  }
}

/// Titles in [bare] have no extras: they end as AI cards.
class _BareServers extends _Servers {
  _BareServers(this.bare);

  final Set<String> bare;

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async =>
      bare.contains(ratingKey) ? const [] : super.extras(serverId, ratingKey, timeout: timeout);
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

/// A deck code arranges (the 1-in-6 AI-card spacing applies).
class _ArrangedDeck extends _Deck {
  _ArrangedDeck(super.id, super.cards);

  @override
  bool get raw => false;
}

class _CountingDeck extends _Deck {
  _CountingDeck(super.id, super.cards, this.onLoad);

  final void Function() onLoad;

  @override
  Future<List<ReelCardData>> load() {
    onLoad();
    return super.load();
  }
}

/// A deck whose load waits on [gate], and throws while [fails] is set.
class _SlowDeck extends _Deck {
  _SlowDeck(super.id, super.cards);

  Completer<void>? gate;
  bool fails = false;
  int loads = 0;

  @override
  Future<List<ReelCardData>> load() async {
    loads++;
    await gate?.future;
    if (fails) throw StateError('server unreachable');
    return super.load();
  }
}

/// A daily deck whose build can land after it loaded.
class _DailyDeck extends ReelDeck {
  _DailyDeck(this.id, this.cards);

  @override
  final String id;
  List<ReelCardData> cards;
  int loads = 0;

  @override
  String get name => 'Deck $id';
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;
  @override
  bool get daily => true;

  @override
  final ValueNotifier<int> rebuilt = ValueNotifier(0);

  @override
  Future<List<ReelCardData>> load() async {
    loads++;
    return cards;
  }

  /// Today's build lands: [next] is what the deck loads from now on.
  void land(List<ReelCardData> next) {
    cards = next;
    rebuilt.value++;
  }
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

/// A Give it another go card: Watch resumes the show.
ReelCardData _resumeCard(String id) {
  final c = _card(id);
  return ReelCardData(title: c.title, facts: c.facts, best: c.best, resume: true);
}

/// The next episode the server has on deck for a show.
MediaItem _episode(String show, {required int season, required int number}) => MediaItem.plex(
  id: 'e$show',
  kind: MediaKind.episode,
  title: 'Harbor Lights $number',
  parentIndex: season,
  index: number,
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
    Listenable? memoryRestored,
    void Function(bool active)? onActive,
    ReelServers? servers,
    AniListLookup? aniList,
    AnimeThemesFetch? animeThemes,
    ValueListenable<ReelPlaybackProfile>? profile,
    ReelItemWithNext? itemWithNext,
    ReelMoreLike? moreLike,
    Future<void> Function(bool muted)? saveMuted,
    int? Function()? plays,
    ReelClipEnd Function()? clipEnd,
    Listenable? settingsChanged,
    Listenable? deckPrefsChanged,
    ReelCellular Function()? cellular,
    bool Function()? metered,
    Listenable? linkChanged,
  }) => ReelController(
    decks:
        decks ??
        [
          _Deck('a', [_card('1'), _card('2'), _card('3')]),
        ],
    resolver: ClipResolver(
      servers: servers ?? _Servers(),
      store: store,
      aniList: aniList ?? (_) async => null,
      animeThemes: animeThemes ?? (_) async => const {},
      profile: profile,
    ),
    clips: ClipPlayer(
      plays: plays,
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
    memoryRestored: memoryRestored,
    onActive: onActive,
    itemWithNext: itemWithNext,
    moreLike: moreLike,
    saveMuted: saveMuted,
    clipEnd: clipEnd,
    settingsChanged: settingsChanged,
    deckPrefsChanged: deckPrefsChanged,
    cellular: cellular,
    metered: metered,
    linkChanged: linkChanged,
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

  test('V2-60: the active hook hears start and suspend, and a dispose while playing gives the brain back', () async {
    final heard = <bool>[];
    final c = make(onActive: heard.add);
    await c.start();
    await c.start(); // already active: no second call
    expect(heard, [true]);
    await c.suspend();
    expect(heard, [true, false]);
    await c.start();
    c.dispose();
    expect(heard, [true, false, true, false]);
  });

  test('V2-60: a dispose after a suspend says nothing more', () async {
    final heard = <bool>[];
    final c = make(onActive: heard.add);
    await c.start();
    await c.suspend();
    c.dispose();
    expect(heard, [true, false]);
  });

  group('Give it another go', () {
    test("a resume card's one metadata read brings its next episode, and Watch names it", () async {
      final asked = <String>[];
      final c = make(
        decks: [
          _Deck('a', [_resumeCard('1'), _card('2'), _resumeCard('3')]),
        ],
        itemWithNext: (serverId, ratingKey) async {
          asked.add(ratingKey);
          return (
            item: await _Media().item(serverId, ratingKey),
            next: ratingKey == '1' ? _episode('1', season: 1, number: 4) : _episode('3', season: 2, number: 3),
          );
        },
      );
      await c.start();
      expect(c.current.item?.id, '1');
      expect(c.current.resumeEpisode, 'E4');
      await c.step(1);
      expect(c.current.resumeEpisode, isNull, reason: 'not a resume card: Watch reads as usual');
      await c.step(1);
      expect(c.current.resumeEpisode, 'S2 E3');
      expect(asked.toSet(), {'1', '3'}, reason: 'other cards read their metadata as before');
      c.dispose();
    });

    test('with no next-episode read, or none on deck, a resume card reads Watch', () async {
      final plain = make(
        decks: [
          _Deck('a', [_resumeCard('1')]),
        ],
      );
      await plain.start();
      expect(plain.current.item?.id, '1');
      expect(plain.current.resumeEpisode, isNull);
      plain.dispose();

      final noneOnDeck = make(
        decks: [
          _Deck('a', [_resumeCard('1')]),
        ],
        itemWithNext: (serverId, ratingKey) async => (item: await _Media().item(serverId, ratingKey), next: null),
      );
      await noneOnDeck.start();
      expect(noneOnDeck.current.item?.id, '1');
      expect(noneOnDeck.current.resumeEpisode, isNull);
      noneOnDeck.dispose();
    });
  });

  test('the first card plays its trailer and the next one is preloaded after its first frame', () async {
    final c = make();
    await c.start();
    await Future<void>.delayed(Duration.zero);
    expect(c.current.card?.id, 't1');
    expect(engine.calls, contains('open https://s1.example/services/iva/assets/1/video.mp4'));
    expect(engine.calls.where((x) => x.startsWith('preload ')), isEmpty, reason: 'the lookahead waits for the frame');
    engine.firstFrameCtl.add(null);
    await pumpEventQueue();
    expect(engine.calls, contains('preload https://s1.example/services/iva/assets/2/video.mp4'));
    c.dispose();
  });

  test('the mute is kept: each toggle is saved, and an unmute is recorded (V2-22)', () async {
    final saved = <bool>[];
    final c = make(saveMuted: (m) async => saved.add(m));
    await c.start();
    await c.setMuted(true);
    expect(c.clips.muted, isTrue);
    await c.setMuted(false);
    expect(c.clips.muted, isFalse);
    expect(saved, [true, false]);
    final events = await store.events(since: DateTime(2000));
    expect(events.map((e) => e.action), contains(ReelAction.unmute.name));
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

  group('V2-29: Save shows saved state', () {
    test('a saved card reads as saved at once; a silent Save says nothing', () async {
      final c = make();
      await c.start();
      expect(c.isSaved('t1'), isFalse);
      var heard = 0;
      c.addListener(() => heard++);
      final saving = c.save(silent: true);
      expect(c.isSaved('t1'), isTrue, reason: 'before the write lands');
      expect(heard, greaterThan(0));
      await saving;
      await pumpEventQueue();
      expect(c.isSaved('t1'), isTrue);
      expect(c.isSaved('t2'), isFalse);
      expect((await store.freshPicks()).map((p) => p.titleId), ['t1']);
      expect(seated, 1);
      expect(c.toast.value, isNull);
      c.dispose();
    });

    test('a pick already kept (this device or synced) shows as saved; a stale one does not', () async {
      // The store prunes by the wall clock, so the picks are dated from it.
      final now = DateTime.now().toUtc();
      ReelPick pick(String id, DateTime at) =>
          ReelPick(titleId: id, groupKey: 'g', serverId: 's1', ratingKey: '1', title: 'Harbor Lights', at: at);
      // Written as the synced list, as a stale pick sits there until the
      // next save prunes it.
      final settings = LocalCustomisationStore(db);
      final raw = jsonEncode([
        pick('t2', now.subtract(const Duration(hours: 5))).toJson(),
        pick('t3', now.subtract(const Duration(days: 4))).toJson(),
      ]);
      await settings.writeSetting(ReelStore.picksKey, raw);
      store = ReelStore(database: () async => db, settings: () async => settings);
      final c = make();
      await c.start();
      await pumpEventQueue();
      expect(c.isSaved('t2'), isTrue);
      expect(c.isSaved('t3'), isFalse, reason: 'past the 3 days on Home');
      expect(c.isSaved('t1'), isFalse);
      c.dispose();
    });

    test('a Save the mirror could not keep goes back to unsaved and still says so when silent', () async {
      store = ReelStore(
        database: () async => db,
        settings: () async => MirrorCustomisationStore({}, send: (_) => false),
      );
      final c = make();
      await c.start();
      await c.save(silent: true);
      expect(c.isSaved('t1'), isFalse);
      expect(c.toast.value, ReelController.notConnected);
      c.dispose();
    });
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

    test('Watch hands over the full read, not the card\'s own item', () async {
      final media = _Media();
      final watched = <String>[];
      final c = make(
        media: media,
        onWatch: (item, {required onTv}) async {
          watched.add(item.title ?? '');
          return true;
        },
      );
      await c.start();
      await pumpEventQueue();
      expect(c.current.item?.title, 'Title 1');
      expect(await c.watch(), isTrue);
      expect(watched, ['Full 1']);
      expect(media.fullReads, 1);
      c.dispose();
    });

    test('Watch falls back to the card\'s item when the full read fails', () async {
      final watched = <String>[];
      final c = make(
        media: _NoFullMedia(),
        onWatch: (item, {required onTv}) async {
          watched.add(item.title ?? '');
          return true;
        },
      );
      await c.start();
      await pumpEventQueue();
      expect(await c.watch(), isTrue);
      expect(watched, ['Title 1']);
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

  group('the clip never waits on metadata (V2-03)', () {
    test('the clip opens while the card\'s metadata is still on its way', () async {
      final media = _GatedMedia('1');
      final c = make(media: media);
      await c.start();
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, contains('open https://s1.example/services/iva/assets/1/video.mp4'));
      expect(c.current.item, isNull, reason: 'title-only until the art and text land');

      var redraws = 0;
      c.addListener(() => redraws++);
      media.gate.complete();
      await pumpEventQueue();
      expect(c.current.item?.title, 'Title 1');
      expect(redraws, greaterThan(0));
      c.dispose();
    });

    test('a failed metadata read is asked again when the card is next needed', () async {
      final c = make(media: _LateMedia());
      await c.start();
      await pumpEventQueue();
      expect(c.current.item, isNull, reason: 'the first read failed');
      await c.step(1);
      await c.step(-1);
      await pumpEventQueue();
      expect(c.current.card?.id, 't1');
      expect(c.current.item?.title, 'Title 1');
      c.dispose();
    });

    test('an item that landed is read only once', () async {
      var reads = 0;
      final c = make(media: _CountingMedia(() => reads++));
      await c.start();
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(reads, 3, reason: 'the card on screen and the two ahead');
      await c.step(1);
      await c.step(-1);
      await pumpEventQueue();
      expect(c.current.item, isNotNull);
      expect(reads, 3, reason: 'items that landed are kept for the session');
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

  for (final viaOpen in [false, true]) {
    test('a card still resolving when the deck changes never plays (${viaOpen ? 'openDeck' : 'switchDeck'})', () async {
      final servers = _GatedServers('2');
      final slow = _SlowDeck('b', [_card('5')])..gate = Completer<void>();
      final c = make(
        servers: servers,
        decks: [
          _Deck('a', [_card('1'), _card('2')]),
          slow,
        ],
      );
      await c.start();
      final stepping = c.step(1); // card 2 waits on its server
      await Future<void>.delayed(Duration.zero);
      final switching = viaOpen ? c.openDeck('b') : c.switchDeck(1); // deck b waits on its load
      await Future<void>.delayed(Duration.zero);
      servers.gate.complete();
      await stepping;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      slow.gate!.complete();
      await switching;
      expect(engine.calls, isNot(contains('open https://s1.example/services/iva/assets/2/video.mp4')));
      expect(c.deck.id, 'b');
      expect(c.current.card?.id, 't5');
      expect(engine.calls, contains('open https://s1.example/services/iva/assets/5/video.mp4'));
      c.dispose();
    });
  }

  group('On TV mode opens on the Fold\'s card (V2-48)', () {
    List<ReelDeck> two() => [
      _Deck('a', [_card('1'), _card('2'), _card('3')]),
      _Deck('b', [_card('4'), _card('5'), _card('6')]),
    ];

    test('a first start opens the deck on the card for the title', () async {
      final c = make(decks: two());
      await c.start(deckId: 'b', groupKey: 'g5');
      expect(c.deck.id, 'b');
      expect(c.current.card?.id, 't5');
      c.dispose();
    });

    test('a title the deck does not have leaves the deck on its own cursor', () async {
      final c = make(decks: two());
      await c.start();
      await c.openAt('b', 'g-not-here');
      expect(c.deck.id, 'b');
      expect(c.current.card?.id, 't4');
      await c.step(1);
      await c.openAt('a');
      await c.openAt('b', 'g-still-not-here');
      expect(c.current.card?.id, 't5', reason: 'the deck kept its place');
      c.dispose();
    });

    test('while playing: another deck opens on the card; the same deck moves to it', () async {
      final c = make(decks: two());
      await c.start();
      expect(c.current.card?.id, 't1');
      await c.openAt('b', 'g6');
      expect(c.deck.id, 'b');
      expect(c.current.card?.id, 't6');

      await c.openAt('b', 'g4');
      expect(c.current.card?.id, 't4');
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, contains('open https://s1.example/services/iva/assets/4/video.mp4'));

      final changed = c.cardChanged.value;
      await c.openAt('b', 'g4');
      expect(c.cardChanged.value, changed, reason: 'already on it: nothing reopens');
      c.dispose();
    });

    test('openDeck on the deck already playing stays where it is', () async {
      final c = make(decks: two());
      await c.start();
      await c.step(1);
      await c.openDeck('a');
      expect(c.current.card?.id, 't2');
      c.dispose();
    });
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

  test('Stills only on mobile data opens no clip core; off mobile data it plays again', () async {
    var onCellular = true;
    final link = ValueNotifier(0);
    final c = make(cellular: () => ReelCellular.stillsOnly, metered: () => onCellular, linkChanged: link);
    await c.start();
    await Future<void>.delayed(Duration.zero);
    expect(c.dataBudget, ReelDataBudget.stills);
    expect(engines, 0, reason: 'no clip core and no preload on stills');
    expect(c.current.card?.id, 't1');

    onCellular = false;
    link.value++;
    expect(c.dataBudget, ReelDataBudget.full);
    await c.step(1);
    await Future<void>.delayed(Duration.zero);
    expect(engine.calls, contains('open https://s1.example/services/iva/assets/2/video.mp4'));
    expect(engine.calls, contains('preload https://s1.example/services/iva/assets/3/video.mp4'));
    c.dispose();
    link.dispose();
  });

  test('moving to mobile data on Stills only mid-session releases the playing clip core', () async {
    var onCellular = false;
    final link = ValueNotifier(0);
    final c = make(cellular: () => ReelCellular.stillsOnly, metered: () => onCellular, linkChanged: link);
    await c.start();
    await Future<void>.delayed(Duration.zero);
    final first = engine;
    expect(first.calls, contains('open https://s1.example/services/iva/assets/1/video.mp4'));

    onCellular = true;
    link.value++;
    await c.step(1);
    await Future<void>.delayed(Duration.zero);
    expect(c.current.card?.id, 't2');
    expect(first.disposed, isTrue, reason: 'the last clip stops with its preload');
    final made = engines;
    await c.step(1);
    await Future<void>.delayed(Duration.zero);
    expect(engines, made, reason: 'no new clip core on stills');
    c.dispose();
    link.dispose();
  });

  test('Data saver on mobile data still plays the card and preloads the next', () async {
    final c = make(cellular: () => ReelCellular.dataSaver, metered: () => true);
    await c.start();
    await Future<void>.delayed(Duration.zero);
    expect(c.dataBudget, ReelDataBudget.saver);
    expect(engine.calls, contains('open https://s1.example/services/iva/assets/1/video.mp4'));
    // The lookahead waits for the card's first frame (V2-11).
    engine.firstFrameCtl.add(null);
    await pumpEventQueue();
    expect(engine.calls, contains('preload https://s1.example/services/iva/assets/2/video.mp4'));
    c.dispose();
  });

  test('the views hear about the link only when mobile data comes or goes', () async {
    var onCellular = false;
    final link = ValueNotifier(0);
    final c = make(metered: () => onCellular, linkChanged: link);
    var told = 0;
    c.addListener(() => told++);

    link.value++;
    expect(told, 0, reason: 'still on Wi-Fi');
    onCellular = true;
    link.value++;
    expect(told, 1);
    expect(c.dataBudget, ReelDataBudget.saver, reason: 'Data saver is the default');
    link.value++;
    expect(told, 1);

    c.dispose();
    onCellular = false;
    link.value++;
    expect(told, 1, reason: 'a disposed Reel stops listening');
    link.dispose();
  });

  test('the ladder holds across visits until the memory policy restores', () async {
    final restored = ValueNotifier(0);
    final c = make(memoryRestored: restored);
    await c.start();
    await c.trimMemory();
    await c.trimMemory();
    expect(c.memoryLevel, 2);
    await c.suspend();
    final made = engines;
    await c.start();
    await Future<void>.delayed(Duration.zero);
    expect(c.memoryLevel, 2, reason: 'coming back says nothing about memory');
    expect(engines, made, reason: 'still stills only');

    var told = 0;
    c.addListener(() => told++);
    restored.value++;
    expect(c.memoryLevel, 0);
    expect(told, 1);
    await c.step(1);
    await Future<void>.delayed(Duration.zero);
    expect(engines, greaterThan(made), reason: 'the clip core is rebuilt');
    expect(engine.calls.where((x) => x.startsWith('open ')), isNotEmpty);
    engine.firstFrameCtl.add(null);
    await pumpEventQueue();
    expect(engine.calls.where((x) => x.startsWith('preload ')), isNotEmpty);
    c.dispose();
    restored.value++;
    restored.dispose();
  });

  test('a settings change reaches the views of a playing Reel, and stops at dispose', () async {
    final changed = ValueNotifier(0);
    final c = make(settingsChanged: changed);
    await c.start();
    await Future<void>.delayed(Duration.zero);
    final card = c.current.card?.id;
    final made = engines;

    var told = 0;
    c.addListener(() => told++);
    changed.value++;
    expect(told, 1, reason: 'the views rebuild and read the new choice');
    expect(c.current.card?.id, card, reason: 'no restart: the same card stays');
    expect(engines, made, reason: 'and the clip core is not rebuilt');

    c.dispose();
    expect(() => changed.value++, returnsNormally, reason: 'the listener left with the controller');
    expect(told, 1);
    changed.dispose();
  });

  test('the watchdog tiers map to the ladder: halved is 1, cleared is 2', () async {
    final c = make();
    await c.start();
    await Future<void>.delayed(Duration.zero);
    final first = engine;
    await c.trimForWatchdog(WatchdogTrim.none);
    expect(c.memoryLevel, 0);
    await c.trimForWatchdog(WatchdogTrim.halved);
    expect(c.memoryLevel, 1);
    expect(first.calls.last, 'clearPreloads');
    expect(first.disposed, isFalse, reason: 'level 1 keeps the card on screen playing');
    await c.trimForWatchdog(WatchdogTrim.halved);
    expect(c.memoryLevel, 1, reason: 'a second halving tick is not a second step');
    await c.trimMemory();
    expect(c.memoryLevel, 2);
    expect(first.disposed, isTrue);
    await c.trimForWatchdog(WatchdogTrim.halved);
    expect(c.memoryLevel, 2, reason: 'the ladder never climbs back on a trim');
    c.dispose();
  });

  test('a cleared watchdog tick goes straight to stills', () async {
    final c = make();
    await c.start();
    await Future<void>.delayed(Duration.zero);
    await c.trimForWatchdog(WatchdogTrim.cleared);
    expect(c.memoryLevel, 2);
    expect(engine.disposed, isTrue);
    c.dispose();
  });

  test('level 1 tells the views, so the phone feed can shrink', () async {
    final c = make(externalClips: true);
    await c.start();
    // The cards' art and text land after start (they never hold the clip).
    await pumpEventQueue();
    var told = 0;
    c.addListener(() => told++);
    await c.trimForWatchdog(WatchdogTrim.halved);
    expect(c.memoryLevel, 1);
    expect(told, 1);
    expect(engines, 0, reason: 'the phone has no clip core to trim');
    await c.trimForWatchdog(WatchdogTrim.halved);
    expect(told, 1, reason: 'nothing changed, nothing to redraw');
    c.dispose();
  });

  test('trims and suspend do not wait for an open that never finishes', () async {
    final c = make();
    await c.start();
    await Future<void>.delayed(Duration.zero);
    // The next card's open hangs (a stalled server), so its step never returns.
    final core = engine..openGate = Completer<void>();
    unawaited(c.step(1));
    bool opening() => core.calls.any((x) => x.startsWith('open ') && x.endsWith('/2/video.mp4'));
    // The outgoing clip fades out first.
    for (var i = 0; i < 50 && !opening(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(opening(), isTrue);
    await c.trimForWatchdog(WatchdogTrim.cleared).timeout(const Duration(seconds: 1));
    expect(core.disposed, isTrue);
    await c.suspend().timeout(const Duration(seconds: 1));
    expect(c.active, isFalse);
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

  test('a new playback profile re-picks the files of the cards ahead, not the one on screen (V2-16)', () async {
    ReelCardData anime(String id) => ReelCardData(
      title: ReelTitle(
        titleId: 't$id',
        groupKey: 'g$id',
        title: 'Harbor Lights $id',
        isShow: true,
        anime: true,
        tvdbId: int.parse(id),
        copies: [ReelCopy(serverId: 's1', ratingKey: id)],
      ),
      facts: TitleFacts(
        ref: TitleRef(id: 't$id', groupKey: 'g$id'),
        seen: SeenState.unseen,
      ),
      best: _copy(id),
    );
    Map<String, dynamic> record(int id) => {
      'animethemes': [
        {
          'type': 'OP',
          'sequence': 1,
          'animethemeentries': [
            {
              'episodes': '1-12',
              'videos': [
                for (final res in [720, 1080])
                  {
                    'id': id * 10000 + res,
                    'link': 'https://v.animethemes.moe/OP$id-$res.webm',
                    'nc': true,
                    'resolution': res,
                    'overlap': 'NONE',
                  },
              ],
            },
          ],
        },
      ],
    };
    final profile = ValueNotifier(const ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 1080));
    addTearDown(profile.dispose);
    final c = make(
      externalClips: true,
      decks: [
        _Deck('a', [anime('1'), anime('2'), anime('3')]),
      ],
      aniList: (t) async => t.tvdbId,
      animeThemes: (ids) async => {for (final id in ids) id: record(id)},
      profile: profile,
    );
    await c.start();
    await Future<void>.delayed(Duration.zero);
    expect(c.current.clip?.height, 1080);
    expect(c.slotAt(1).clip?.height, 1080);
    var told = 0;
    c.addListener(() => told++);

    // The Fold folds to its cover screen.
    profile.value = const ReelPlaybackProfile(screen: ReelScreen.compactPortrait, maxHeight: 720);
    expect(c.current.clip?.height, 1080, reason: 'the clip on screen keeps playing its file');
    expect(c.slotAt(1).clip?.height, 720);
    expect(c.slotAt(1).clip?.source.uri, 'https://v.animethemes.moe/OP2-720.webm');
    expect(told, 1);

    c.dispose();
    profile.value = const ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 1080);
    expect(told, 1, reason: 'a disposed controller stops listening');
  });

  test('opening a deck asks AnimeThemes once for all its anime shows (V2-12)', () async {
    ReelCardData anime(String id) => ReelCardData(
      title: ReelTitle(
        titleId: 't$id',
        groupKey: 'g$id',
        title: 'Harbor Lights $id',
        isShow: true,
        anime: true,
        tvdbId: int.parse(id),
        copies: [ReelCopy(serverId: 's1', ratingKey: id)],
      ),
      facts: TitleFacts(
        ref: TitleRef(id: 't$id', groupKey: 'g$id'),
        seen: SeenState.unseen,
      ),
      best: _copy(id),
    );
    final batches = <List<int>>[];
    final c = make(
      decks: [
        _Deck('a', [anime('1'), anime('2'), _card('3'), anime('4'), anime('5')]),
      ],
      aniList: (t) async => t.tvdbId,
      animeThemes: (ids) async {
        batches.add(ids);
        return {
          for (final id in ids)
            id: {
              'animethemes': [
                {
                  'type': 'OP',
                  'sequence': 1,
                  'animethemeentries': [
                    {
                      'episodes': '1-12',
                      'videos': [
                        {
                          'id': id,
                          'link': 'https://v.animethemes.moe/OP$id.webm',
                          'resolution': 1080,
                          'overlap': 'NONE',
                        },
                      ],
                    },
                  ],
                },
              ],
            },
        };
      },
    );
    await c.start();
    await c.step(1);
    await c.step(1);
    engine.firstFrameCtl.add(null);
    await pumpEventQueue();
    expect(c.current.card?.id, 't3');
    expect(c.slotAt(3).clip?.assetId, 'at:4');
    expect(batches, [
      [1, 2, 4, 5],
    ], reason: 'the first card waits for the batch; no card asks on its own');
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

  group('mute (V2-22)', () {
    setUp(resetSharedPreferencesForTest);

    test('an unmute is recorded and the choice kept for the next launch', () async {
      final settings = await SettingsService.getInstance();
      final c = make(externalClips: true);
      await c.start();
      await c.setMuted(true);
      expect(c.muted, isTrue);
      expect(settings.read(SettingsService.reelMuted), isTrue);
      await c.setMuted(false);
      expect(settings.read(SettingsService.reelMuted), isFalse);
      final events = await store.events(since: DateTime(2000));
      expect(events.map((e) => e.action).where((a) => a == ReelAction.unmute.name), hasLength(1));
      c.dispose();
    });

    test('a mute the visit starts with is neither recorded nor kept', () async {
      final settings = await SettingsService.getInstance();
      final c = make(externalClips: true);
      await c.start();
      await c.setMuted(true, remember: false);
      expect(c.muted, isTrue);
      await c.setMuted(false, remember: false);
      expect(settings.read(SettingsService.reelMuted), isFalse);
      final events = await store.events(since: DateTime(2000));
      expect(events.map((e) => e.action), isNot(contains(ReelAction.unmute.name)));
      c.dispose();
    });
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

  group("Tonight's picks", () {
    Future<void> saved(String id, {Duration ago = Duration.zero}) => store.savePick(
      ReelPick(
        titleId: 't$id',
        groupKey: 'g$id',
        serverId: 's1',
        ratingKey: id,
        title: 'Title $id',
        at: DateTime.now().toUtc().subtract(ago),
      ),
    );

    List<String> pages(ReelController c) => [
      for (var i = 0; i < c.slotCount; i++)
        switch (c.slotAt(i)) {
          ReelSlot(kind: ReelSlotKind.card, :final card?) => card.id,
          ReelSlot(:final kind) => kind.name,
        },
    ];

    test('after the second Save it comes up next; the page on screen stays put', () async {
      final c = make(
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3'), _card('4')]),
        ],
      );
      await c.start();
      expect(pages(c), ['t1', 't2', 't3', 't4', 'poolEnd'], reason: 'no fresh picks: the end as before');
      await c.save();
      expect(pages(c), [
        't1',
        't2',
        't3',
        't4',
        'decide',
        'poolEnd',
      ], reason: 'one Save: it waits at the end of the deck');
      await c.step(1);
      await c.save();
      expect(pages(c), ['t1', 't2', 'decide', 't3', 't4', 'poolEnd']);
      expect(c.page, 1);
      expect(c.index, 1);
      expect(c.current.card?.id, 't2');

      await c.step(1);
      expect(c.current.kind, ReelSlotKind.decide);
      expect(c.current.picks.map((p) => p.pick.titleId), ['t2', 't1'], reason: 'newest first');
      expect(c.current.chosen?.pick.titleId, 't2');
      await pumpEventQueue();
      expect(c.current.picks.map((p) => p.item?.id), ['2', '1'], reason: "the picks' metadata is read");
      expect(c.upNext.first.card?.id, 't3');

      await c.step(1);
      expect(c.current.card?.id, 't3', reason: 'swiping on goes to the next card');
      expect(c.page, 3);
      await c.step(-1);
      expect(c.current.kind, ReelSlotKind.decide, reason: 'it stays where it was, so the pages hold');
      c.dispose();
    });

    test("a held ↓ on the TV (V2-66) counts in pages: the decision card is one, and the end is the last", () async {
      final c = make(
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3'), _card('4')]),
        ],
      );
      expect(ReelHeldStep.cursorOf(c), isNull, reason: 'no deck yet');
      await c.start();
      await c.save();
      await c.step(1);
      await c.save();
      expect(pages(c), ['t1', 't2', 'decide', 't3', 't4', 'poolEnd']);
      await c.step(1);
      await c.step(1);
      expect(c.current.card?.id, 't3');
      final at = ReelHeldStep.cursorOf(c)!;
      expect(c.slotAt(at.index).card?.id, 't3', reason: 'the preview starts on the card that shows');
      expect(c.slotAt(at.last).kind, ReelSlotKind.poolEnd);
      c.dispose();
    });

    test('at most once a session: a third Save after it was seen places nothing new', () async {
      final c = make(
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3'), _card('4'), _card('5')]),
        ],
      );
      await c.start();
      await c.save();
      await c.step(1);
      await c.save();
      await c.step(1);
      expect(c.current.kind, ReelSlotKind.decide);
      await c.step(1);
      await c.save();
      await c.step(1);
      await c.save();
      expect(pages(c).where((p) => p == 'decide'), hasLength(1));
      expect(pages(c).indexOf('decide'), 2);
      c.dispose();
    });

    test('a warm controller starts a new session on a new day: it can come up again', () async {
      // Saves are kept by this clock and read back fresh by the store's.
      var now = DateTime.now();
      final c = make(
        clock: () => now,
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3'), _card('4'), _card('5'), _card('6')]),
        ],
      );
      await c.start();
      await c.save();
      await c.step(1);
      await c.save();
      await c.step(1);
      expect(c.current.kind, ReelSlotKind.decide);
      await c.step(1);
      await c.suspend();

      await c.start();
      expect(pages(c).where((p) => p == 'decide'), hasLength(1), reason: 'same day: spent');
      await c.suspend();

      now = DateTime(now.year, now.month, now.day + 1, 12);
      await c.start();
      expect(c.current.card?.id, 't3', reason: 'the deck keeps its place');
      expect(pages(c), ['t1', 't2', 't3', 't4', 't5', 't6', 'decide', 'poolEnd'], reason: 'unplaced again');
      await c.save();
      await c.step(1);
      await c.save();
      expect(pages(c).indexOf('decide'), 4, reason: 'after the day\'s second Save it comes up next');
      c.dispose();
    });

    test('at the end of a deck it comes before the end card when there are fresh picks', () async {
      await saved('8');
      await saved('9', ago: const Duration(days: 4));
      final c = make();
      await c.start();
      expect(pages(c), ['t1', 't2', 't3', 'decide', 'poolEnd']);
      await c.step(1);
      await c.step(1);
      await c.step(1);
      expect(c.current.kind, ReelSlotKind.decide);
      expect(c.current.picks.map((p) => p.pick.titleId), ['t8'], reason: 'only fresh Saves');
      expect(engine.calls.last, 'pause', reason: 'nothing plays under it');
      await c.step(1);
      expect(c.current.kind, ReelSlotKind.poolEnd);
      c.dispose();
    });

    test('once seen in one deck, the end of the others is as before', () async {
      await saved('8');
      final c = make(
        decks: [
          _Deck('a', [_card('1')]),
          _Deck('b', [_card('2')]),
        ],
      );
      await c.start();
      expect(pages(c), ['t1', 'decide', 'poolEnd']);
      await c.step(1);
      await c.switchDeck(1);
      expect(pages(c), ['t2', 'poolEnd']);
      await c.switchDeck(1);
      expect(pages(c), ['t1', 'decide', 'poolEnd']);
      expect(c.current.kind, ReelSlotKind.decide, reason: "the deck's own cursor stays on it");
      c.dispose();
    });

    test('left and right choose a pick, stopping at either end; Watch hands the chosen one over', () async {
      await saved('7', ago: const Duration(hours: 2));
      await saved('8', ago: const Duration(hours: 1));
      await saved('9');
      final handed = <String>[];
      final c = make(
        decks: [
          _Deck('a', [_card('1')]),
        ],
        onWatch: (item, {required onTv}) async {
          handed.add('${item.id}${onTv ? ' on TV' : ''}');
          return true;
        },
      );
      await c.start();
      await c.step(1);
      expect(c.current.pick, 0);
      c.movePick(-1);
      expect(c.current.pick, 0);
      c.movePick(1);
      c.movePick(1);
      c.movePick(1);
      expect(c.current.pick, 2);
      expect(c.remoteState()['decide'], {
        'pick': 2,
        'picks': [
          for (final id in ['9', '8', '7'])
            {'id': 't$id', 'title': 'Title $id', 'year': null, 'server': 's1', 'art': null, 'thumb': null},
        ],
      });
      expect(c.remoteState()['card'], isNull);
      c.selectPick(1);
      expect(await c.watch(), isTrue);
      expect(await c.watch(onTv: true), isTrue);
      expect(handed, ['8', '8 on TV']);
      final events = await store.events(since: DateTime(2000));
      expect(events.where((e) => e.action == ReelAction.watch.name).map((e) => e.titleId), ['t8']);
      c.dispose();
    });

    test("a pick's Watch hands over the full read, as a card's does, and clears the queue", () async {
      await saved('8');
      final handed = <String?>[];
      final c = make(
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3')]),
        ],
        onWatch: (item, {required onTv}) async {
          handed.add(item.title);
          return true;
        },
      );
      await c.start();
      await c.step(3);
      expect(c.current.kind, ReelSlotKind.decide);
      expect(await c.watch(), isTrue);
      expect(handed, ['Full 8'], reason: 'the lean row may lack the streams playback needs');
      expect(c.prefetcher.queued, isEmpty);
      c.dispose();
    });

    test('card actions do nothing on it', () async {
      await saved('8');
      final c = make(
        decks: [
          _Deck('a', [_card('1')])..keeps = false,
        ],
        moreLike: (seed, {required skip}) async => [_card('7')],
      );
      await c.start();
      await c.step(1);
      expect(c.canMoreLike, isFalse);
      await c.notForMe();
      await c.seenIt();
      expect(pages(c), ['t1', 'decide', 'poolEnd']);
      expect(c.current.kind, ReelSlotKind.decide);
      c.dispose();
    });

    test('Not for me on the card before it: it slides in, on the same page', () async {
      final c = make(
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3')]),
        ],
      );
      await c.start();
      await c.save();
      await c.save();
      expect(pages(c), ['t1', 'decide', 't2', 't3', 'poolEnd']);
      await c.notForMe();
      expect(pages(c), ['decide', 't2', 't3', 'poolEnd']);
      expect(c.page, 0);
      expect(c.current.kind, ReelSlotKind.decide);
      c.dispose();
    });

    test('More like this pressed before it: the new cards come first, then it', () async {
      final c = make(
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3')]),
        ],
        moreLike: (seed, {required skip}) async => [_card('2'), _card('7')],
      );
      await c.start();
      await c.save();
      await c.save();
      expect(pages(c), ['t1', 'decide', 't2', 't3', 'poolEnd']);
      await c.moreLikeThis();
      expect(pages(c), ['t1', 't2', 't7', 'decide', 't3', 'poolEnd']);
      expect(c.page, 0);
      c.dispose();
    });

    test("today's build landing while it waits ahead keeps it next", () async {
      final fy = _DailyDeck('fy', [_card('1'), _card('2'), _card('3')]);
      final c = make(decks: [fy]);
      await c.start();
      await c.save();
      await c.save();
      expect(pages(c), ['t1', 'decide', 't2', 't3', 'poolEnd']);
      fy.land([_card('5'), _card('6')]);
      await pumpEventQueue();
      expect(pages(c), ['t1', 'decide', 't5', 't6', 'poolEnd']);
      expect(c.page, 0);
      c.dispose();
    });

    test("today's build landing on it at the end of the deck: it stays put and the new cards follow", () async {
      await saved('8');
      final fy = _DailyDeck('fy', [_card('1')]);
      final c = make(decks: [fy]);
      await c.start();
      await c.step(1);
      expect(c.current.kind, ReelSlotKind.decide);
      fy.land([_card('5')]);
      await pumpEventQueue();
      expect(pages(c), ['t1', 'decide', 't5', 'poolEnd']);
      expect(c.current.kind, ReelSlotKind.decide);
      c.dispose();
    });
  });

  group('More like this', () {
    test('the chosen cards come straight after the card on screen, and the cursor stays', () async {
      ReelCardData? seedAsked;
      Set<String>? skipped;
      final said = <String>[];
      final c = make(
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3'), _card('4')]),
        ],
        moreLike: (seed, {required skip}) async {
          seedAsked = seed;
          skipped = skip;
          return [_card('7'), _card('8')];
        },
      );
      c.toast.addListener(() => said.add(c.toast.value ?? ''));
      await c.start();
      await c.step(1);
      expect(c.canMoreLike, isTrue);
      await c.moreLikeThis();
      expect(seedAsked?.id, 't2');
      expect(skipped, {'t1', 't2'}, reason: 'cards already shown stay out');
      expect(c.index, 1);
      expect(c.current.card?.id, 't2');
      expect(c.cards?.map((x) => x.id), ['t1', 't2', 't7', 't8', 't3', 't4']);
      expect(said, [ReelController.findingMoreLike, ReelController.moreLikeUpNext]);
      final events = await store.events(since: DateTime(2000));
      expect(events.where((e) => e.action == ReelAction.moreLikeThis.name).map((e) => e.titleId), [
        't2',
      ], reason: 'the ask is a fact about the seed');
      await c.step(1);
      expect(c.current.card?.id, 't7');
      c.dispose();
    });

    test('a card further down the deck moves up; one already shown, or the seed, never comes back', () async {
      final c = make(
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3'), _card('4')]),
        ],
        moreLike: (seed, {required skip}) async => [_card('1'), _card('2'), _card('4'), _card('9'), _card('9')],
      );
      await c.start();
      await c.step(1);
      await c.moreLikeThis();
      expect(c.cards?.map((x) => x.id), ['t1', 't2', 't4', 't9', 't3']);
      c.dispose();
    });

    test('at most eight cards go in', () async {
      final c = make(moreLike: (seed, {required skip}) async => [for (var i = 10; i < 20; i++) _card('$i')]);
      await c.start();
      await c.moreLikeThis();
      expect(c.cards?.length, 3 + 8);
      c.dispose();
    });

    test('nothing found leaves the deck as it was and says so', () async {
      final said = <String>[];
      final c = make(moreLike: (seed, {required skip}) async => null);
      c.toast.addListener(() => said.add(c.toast.value ?? ''));
      await c.start();
      await c.moreLikeThis();
      expect(c.cards?.map((x) => x.id), ['t1', 't2', 't3']);
      expect(said.last, ReelController.noMoreLike);

      final failing = make(moreLike: (seed, {required skip}) async => throw StateError('offline'));
      await failing.start();
      await failing.moreLikeThis();
      expect(failing.cards?.map((x) => x.id), ['t1', 't2', 't3']);
      failing.dispose();
      c.dispose();
    });

    test('a second press while the call runs joins it: one call, one insert', () async {
      var calls = 0;
      final gate = Completer<List<ReelCardData>?>();
      final c = make(
        moreLike: (seed, {required skip}) {
          calls++;
          return gate.future;
        },
      );
      await c.start();
      final first = c.moreLikeThis();
      final second = c.moreLikeThis();
      gate.complete([_card('7')]);
      await (first, second).wait;
      expect(calls, 1);
      expect(c.cards?.map((x) => x.id), ['t1', 't7', 't2', 't3']);
      c.dispose();
    });

    test('cards land after the card on screen when the call lands, even if the feed moved on', () async {
      final gate = Completer<List<ReelCardData>?>();
      final c = make(moreLike: (seed, {required skip}) => gate.future);
      await c.start();
      final press = c.moreLikeThis();
      await c.step(1);
      await c.step(1);
      await c.step(1);
      expect(c.current.kind, ReelSlotKind.poolEnd);
      gate.complete([_card('7'), _card('8')]);
      await press;
      expect(c.index, 3);
      expect(c.current.card?.id, 't7', reason: 'at the end of the deck the first new card comes on screen');
      c.dispose();
    });

    test('not offered without a finder, or on the end-of-deck card', () async {
      final none = make();
      await none.start();
      expect(none.canMoreLike, isFalse);
      none.dispose();

      final c = make(moreLike: (seed, {required skip}) async => [_card('7')]);
      await c.start();
      for (var i = 0; i < 3; i++) {
        await c.step(1);
      }
      expect(c.current.kind, ReelSlotKind.poolEnd);
      expect(c.canMoreLike, isFalse);
      c.dispose();
    });

    test('in the phone feed the new next card is resolved ahead', () async {
      final c = make(externalClips: true, moreLike: (seed, {required skip}) async => [_card('7')]);
      await c.start();
      await c.moreLikeThis();
      await pumpEventQueue();
      expect(c.slotAt(1).card?.id, 't7');
      expect(c.slotAt(1).resolved, isTrue);
      expect(c.slotAt(1).clip, isNotNull);
      c.dispose();
    });
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

    test('a card that starts mid-swipe, before the settle commits the step, is timed from its start', () async {
      final c = make(externalClips: true, clock: clock);
      await c.start();
      // V2-02: past the middle of the swipe the next card plays; the step
      // only lands when the page comes to rest.
      c.clipStarted('t2');
      now = now.add(const Duration(seconds: 1));
      await c.step(1);
      now = now.add(const Duration(seconds: 8));
      await c.step(1);
      final events = await store.events(since: DateTime(2000));
      expect(events.last.titleId, 't2');
      expect(events.last.action, ReelAction.sampled.name);
      expect(events.last.seconds, 9);
      c.dispose();
    });

    test('a start from a card the swipe went back from does not time a later visit', () async {
      final c = make(externalClips: true, clock: clock);
      await c.start();
      c.clipStarted('t2');
      c.clipLeft('t2');
      now = now.add(const Duration(seconds: 9));
      await c.step(1);
      now = now.add(const Duration(seconds: 9));
      await c.step(1);
      final events = await store.events(since: DateTime(2000));
      expect(events.last.titleId, 't2');
      expect(events.last.action, ReelAction.unplayed.name);
      c.dispose();
    });

    test('a phone player that broke records nothing about the title', () async {
      final c = make(externalClips: true, clock: clock);
      await c.start();
      c.clipStarted('t1');
      await c.clipFailed('t1');
      now = now.add(const Duration(milliseconds: 300));
      await c.step(1);
      expect(await actions(), [ReelAction.unplayed.name]);
      c.dispose();
    });
  });

  group('a held key coalesces steps', () {
    late DateTime now;
    DateTime clock() => now;

    setUp(() => now = DateTime.utc(2026, 3, 1, 20));

    List<String> opens() => [
      for (final x in engine.calls)
        if (x.startsWith('open ')) x.substring(x.lastIndexOf('/assets/') + 8).split('/').first,
    ];

    test('five steps at once move five cards, open one clip and record nothing in between', () async {
      final c = make(
        clock: clock,
        decks: [
          _Deck('a', [for (var i = 1; i <= 7; i++) _card('$i')]),
        ],
      );
      await c.start();
      await Future<void>.delayed(Duration.zero);
      engine.firstFrameCtl.add(null);
      now = now.add(const Duration(seconds: 9));
      engine.calls.clear();

      await Future.wait([for (var k = 0; k < 5; k++) c.step(1)]);
      await Future<void>.delayed(Duration.zero);
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();

      expect(c.index, 5);
      expect(c.current.card?.id, 't6');
      expect(opens(), ['6'], reason: 'only the landed card opens');
      expect(engine.calls, contains('preload https://s1.example/services/iva/assets/7/video.mp4'));
      final events = await store.events(since: DateTime(2000));
      expect([for (final e in events) '${e.titleId} ${e.action}'], ['t1 ${ReelAction.sampled.name}']);
      expect(await store.quickSkips(), isEmpty);
      c.dispose();
    });

    test('a step while the last one is still resolving lands on the later card', () async {
      final media = _GatedServers('2');
      final c = make(
        clock: clock,
        servers: media,
        decks: [
          _Deck('a', [for (var i = 1; i <= 4; i++) _card('$i')]),
        ],
      );
      await c.start();
      await Future<void>.delayed(Duration.zero);
      engine.calls.clear();

      final first = c.step(1);
      await Future<void>.delayed(Duration.zero);
      expect(c.index, 1);
      final second = c.step(1);
      await Future<void>.delayed(Duration.zero);
      // Card 2's extras answer only now; the resolver's queue held card 3
      // behind them.
      media.gate.complete();
      await Future.wait([first, second]);
      await Future<void>.delayed(Duration.zero);

      expect(c.current.card?.id, 't3');
      expect(opens(), ['3'], reason: 'the card passed over while resolving never opens');
      final events = await store.events(since: DateTime(2000));
      expect([for (final e in events) e.titleId], ['t1']);
      c.dispose();
    });

    test('a held ↓ on the TV keys: the press opens its card, the repeats open only the landed one', () async {
      final c = make(
        clock: clock,
        decks: [
          _Deck('a', [for (var i = 1; i <= 9; i++) _card('$i')]),
        ],
      );
      await c.start();
      await Future<void>.delayed(Duration.zero);
      engine.firstFrameCtl.add(null);
      now = now.add(const Duration(seconds: 9));
      engine.calls.clear();

      final pending = <Future<void>>[];
      final held = ReelHeldStep(
        cursor: () => (index: c.index, last: c.cards!.length),
        step: (dir, count) {
          for (var k = 0; k < count; k++) {
            pending.add(c.step(dir));
          }
        },
      );
      const key = LogicalKeyboardKey.arrowDown, physical = PhysicalKeyboardKey.arrowDown;
      held.handle(const KeyDownEvent(physicalKey: physical, logicalKey: key, timeStamp: Duration.zero));
      await Future.wait(pending);
      await Future<void>.delayed(Duration.zero);
      expect(c.current.card?.id, 't2');
      for (var k = 0; k < 5; k++) {
        held.handle(const KeyRepeatEvent(physicalKey: physical, logicalKey: key, timeStamp: Duration.zero));
        await Future<void>.delayed(Duration.zero);
      }
      expect(c.index, 1, reason: 'the cursor waits for the key up');
      expect(held.preview.value, 6);
      held.handle(const KeyUpEvent(physicalKey: physical, logicalKey: key, timeStamp: Duration.zero));
      expect(c.index, 6, reason: 'the cursor lands before the preview clears');
      await Future.wait(pending);
      await Future<void>.delayed(Duration.zero);

      expect(c.current.card?.id, 't7');
      expect(opens(), ['2', '7'], reason: 'cards passed while held never open');
      final events = await store.events(since: DateTime(2000));
      expect(
        [for (final e in events) '${e.titleId} ${e.action}'],
        ['t1 ${ReelAction.sampled.name}', 't2 ${ReelAction.unplayed.name}'],
      );
      expect(await store.quickSkips(), isEmpty);
      held.dispose();
      c.dispose();
    });

    test('steps back past the start stop at the first card', () async {
      final c = make(clock: clock);
      await c.start();
      await Future.wait([c.step(1), c.step(-1), c.step(-1)]);
      expect(c.index, 0);
      expect(c.current.card?.id, 't1');
      c.dispose();
    });
  });

  group("today's build in a session already showing the deck", () {
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));
    List<String?> ids(ReelController c) => [for (final x in c.cards ?? const <ReelCardData>[]) x.id];

    test('it follows the card on screen; the cursor and the card stay put', () async {
      final d = _DailyDeck('fy', [_card('1'), _card('2'), _card('3')]);
      final c = make(decks: [d]);
      await c.start();
      await c.step(1);
      expect(c.current.card?.id, 't2');
      engine.firstFrameCtl.add(null);
      d.land([_card('7'), _card('1'), _card('8'), _card('9')]);
      await settle();
      expect(ids(c), ['t1', 't2', 't7', 't8', 't9']);
      expect(c.index, 1);
      expect(c.current.card?.id, 't2');
      expect(engine.calls, contains('preload https://s1.example/services/iva/assets/7/video.mp4'));
      await c.step(1);
      expect(c.current.card?.id, 't7');
      c.dispose();
    });

    test('a deck that is not on screen takes the new list from its start', () async {
      final d = _DailyDeck('fy', [_card('1'), _card('2')]);
      final c = make(
        decks: [
          d,
          _Deck('b', [_card('5')]),
        ],
      );
      await c.start();
      await c.step(1);
      await c.switchDeck(1);
      d.land([_card('7'), _card('8')]);
      await settle();
      await c.switchDeck(-1);
      expect(ids(c), ['t7', 't8']);
      expect(c.index, 0);
      c.dispose();
    });

    test('at the end of the deck, the first new card comes on screen', () async {
      final d = _DailyDeck('fy', [_card('1')]);
      final c = make(decks: [d]);
      await c.start();
      await c.step(1);
      expect(c.current.kind, ReelSlotKind.poolEnd);
      d.land([_card('1'), _card('6')]);
      await settle();
      expect(c.index, 1);
      expect(c.current.card?.id, 't6');
      c.dispose();
    });

    test('a build that lands empty leaves the list alone', () async {
      final d = _DailyDeck('fy', [_card('1'), _card('2')]);
      final c = make(decks: [d]);
      await c.start();
      d.land(const []);
      await settle();
      expect(ids(c), ['t1', 't2']);
      c.dispose();
    });

    test('a deck that has not loaded yet reads the build when it loads', () async {
      final d = _DailyDeck('fy', [_card('1')]);
      final c = make(
        decks: [
          _Deck('b', [_card('5')]),
          d,
        ],
      );
      await c.start();
      d.land([_card('4')]);
      await settle();
      expect(d.loads, 0);
      await c.switchDeck(1);
      expect(ids(c), ['t4']);
      c.dispose();
    });
  });

  group('a warm controller on a new day', () {
    test('a daily deck loads again on start, from its first card', () async {
      var now = DateTime(2026, 3, 10, 23);
      final d = _DailyDeck('fy', [_card('1'), _card('2')]);
      final keep = _Deck('b', [_card('5'), _card('6')]);
      final c = make(decks: [d, keep], clock: () => now);
      await c.start();
      await c.step(1);
      await c.suspend();
      await c.start();
      expect(d.loads, 1, reason: 'same day: the list is kept');
      expect(c.index, 1);
      await c.suspend();

      now = DateTime(2026, 3, 11, 8);
      d.cards = [_card('3'), _card('4')];
      await c.start();
      expect(d.loads, 2);
      expect(c.index, 0);
      expect(c.current.card?.id, 't3');
      c.dispose();
    });

    test('decks that are not daily keep their list and place', () async {
      var now = DateTime(2026, 3, 10, 23);
      var loads = 0;
      final keep = _CountingDeck('b', [_card('5'), _card('6')], () => loads++);
      final c = make(decks: [keep], clock: () => now);
      await c.start();
      await c.step(1);
      await c.suspend();
      now = DateTime(2026, 3, 11, 8);
      await c.start();
      expect(loads, 1);
      expect(c.current.card?.id, 't6');
      c.dispose();
    });
  });

  group('a failed clip looks again, and unknown answers come back (V2-56)', () {
    test('a TV clip that fails clears its cached answer and plays the next trailer', () async {
      final c = make(servers: _FlakyServers());
      await c.start();
      expect(c.current.clip?.assetId, 'plex:a1');
      expect(engine.calls, contains('open https://s1.example/services/iva/assets/a1/video.mp4'));

      engine.errorCtl.add(const PlayerError('source gone'));
      await pumpEventQueue();
      expect(c.current.clip?.assetId, 'plex:b1');
      // The outgoing clip fades out (250 ms) before the new one opens.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(engine.calls, contains('open https://s1.example/services/iva/assets/b1/video.mp4'));
      expect(await store.cached('src:g1'), contains('plex:b1'));
      c.dispose();
    });

    test('a phone clip that fails is looked up once more, without the failed asset', () async {
      final servers = _FlakyServers();
      final c = make(servers: servers, externalClips: true);
      await c.start();
      expect(c.current.clip?.assetId, 'plex:a1');

      await c.clipFailed('t1');
      expect(c.current.clip?.assetId, 'plex:b1');
      final reads = servers.reads;

      // The second clip failing too leaves the card as it is: once only.
      await c.clipFailed('t1');
      expect(servers.reads, reads);
      expect(c.current.clip?.assetId, 'plex:b1');
      c.dispose();
    });

    test('a failure on a card that is not on screen does nothing', () async {
      final servers = _FlakyServers();
      final c = make(servers: servers, externalClips: true);
      await c.start();
      final reads = servers.reads;
      await c.clipFailed('t2');
      expect(servers.reads, reads);
      c.dispose();
    });

    test('a card whose server was offline is looked up again on resume', () async {
      final servers = _FlakyServers()..offline.add('s1');
      final c = make(servers: servers, externalClips: true);
      await c.start();
      expect(c.current.isAiCard, isTrue);
      expect(await store.cached('src:g1'), isNull, reason: 'unknown is never a cached miss');

      await c.suspend();
      servers.offline.clear();
      await c.start();
      expect(c.current.clip?.assetId, 'plex:a1');
      c.dispose();
    });

    test('a definitive answer is not looked up again on resume', () async {
      final servers = _FlakyServers();
      final c = make(servers: servers, externalClips: true);
      await c.start();
      await pumpEventQueue();
      final reads = servers.reads;
      await c.suspend();
      await c.start();
      await pumpEventQueue();
      expect(servers.reads, reads);
      c.dispose();
    });
  });

  group('one prefetch queue (V2-11)', () {
    List<ReelDeck> deckOf(int n) => [
      _Deck('a', [for (var i = 1; i <= n; i++) _card('$i')]),
    ];

    test('on the TV the cards around wait for the first frame of the one on screen', () async {
      final servers = _RecordingServers();
      final c = make(servers: servers, decks: deckOf(4));
      await c.start();
      await pumpEventQueue();
      expect(servers.reads, ['1']);
      expect(c.prefetcher.held, isTrue);

      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(c.prefetcher.held, isFalse);
      expect(servers.reads, ['1', '2', '3']);
      c.dispose();
    });

    test('after five fast steps the landed card is read first, then +1, -1 and +2', () async {
      final servers = _RecordingServers();
      final c = make(servers: servers, decks: deckOf(9));
      await c.start();
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      servers.reads.clear();

      await Future.wait([for (var k = 0; k < 5; k++) c.step(1)]);
      await pumpEventQueue();
      expect(servers.reads, ['6'], reason: 'cards passed over are never read');
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(servers.reads, ['6', '7', '5', '8']);
      c.dispose();
    });

    test('back up the deck, the window leans the other way', () async {
      final servers = _RecordingServers();
      final c = make(servers: servers, decks: deckOf(9));
      await c.start();
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      await Future.wait([for (var k = 0; k < 6; k++) c.step(1)]);
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      servers.reads.clear();

      await c.step(-1);
      await c.step(-1);
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(servers.reads, ['5', '4'], reason: 'the card on screen and the one above it, then two above');
      c.dispose();
    });

    for (final (name, leave) in [
      ('Watch', (ReelController c) => c.watch()),
      ('suspend', (ReelController c) => c.suspend()),
    ]) {
      test('$name clears the queue: no Reel read follows it', () async {
        final servers = _RecordingServers(gated: '2');
        final media = _RecordingMedia();
        final c = make(servers: servers, media: media, decks: deckOf(4), onWatch: (_, {required onTv}) async => true);
        await c.start();
        engine.firstFrameCtl.add(null);
        await pumpEventQueue();
        expect(servers.reads, ['1', '2'], reason: "card 2's read is in flight");

        await leave(c);
        servers.gate.complete();
        await pumpEventQueue();
        expect(servers.reads, ['1', '2'], reason: 'the read in flight finishes; nothing queued starts');
        expect(media.reads, ['1']);
        expect(c.prefetcher.queued, isEmpty);
        c.dispose();
      });
    }

    test('Watch on TV clears the queue for the hand-over, then the phone\'s window comes back', () async {
      final servers = _RecordingServers(gated: '2');
      final handedOver = <String>[];
      final c = make(
        servers: servers,
        decks: deckOf(4),
        externalClips: true,
        onWatch: (item, {required onTv}) async {
          handedOver.add(servers.reads.join(','));
          return true;
        },
      );
      await c.start();
      await pumpEventQueue();
      expect(servers.reads, ['1', '2'], reason: "card 2's read is in flight");

      expect(await c.watch(onTv: true), isTrue);
      expect(handedOver, ['1,2'], reason: 'nothing new starts before the hand-over');
      servers.gate.complete();
      await pumpEventQueue();
      expect(servers.reads, ['1', '2', '3'], reason: 'the lookahead goes on after Watch on TV');
      c.dispose();
    });

    test('on mobile data only the card on screen and the next are fetched', () async {
      final profile = ValueNotifier(
        const ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 720, link: ReelLink.cellular),
      );
      addTearDown(profile.dispose);
      final servers = _RecordingServers();
      final c = make(servers: servers, decks: deckOf(4), profile: profile);
      await c.start();
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(servers.reads, ['1', '2']);
      expect(c.slotAt(2).resolved, isFalse);
      c.dispose();
    });

    test('memory pressure narrows the queue to the card on screen and the next', () async {
      final servers = _RecordingServers();
      final c = make(servers: servers, decks: deckOf(4));
      await c.start();
      await pumpEventQueue();
      await c.trimMemory();
      expect(c.memoryLevel, 1);
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(servers.reads, ['1', '2']);
      c.dispose();
    });

    test('the phone feed never holds the queue: its parked players need the cards ahead', () async {
      final servers = _RecordingServers();
      final c = make(servers: servers, decks: deckOf(4), externalClips: true);
      await c.start();
      await pumpEventQueue();
      expect(c.prefetcher.held, isFalse);
      expect(servers.reads, ['1', '2', '3']);
      c.dispose();
    });
  });
  group('the next two cards\' art is warmed ahead (V2-13)', () {
    List<ReelDeck> deckOf(int n) => [
      _Deck('a', [for (var i = 1; i <= n; i++) _card('$i')]),
    ];

    /// Records each warm: the card, the item it was given, and whether the
    /// card had a clip.
    List<(String, String, bool)> warmOn(ReelController c) {
      final warmed = <(String, String, bool)>[];
      c.artPrecache = (card, item, {required clip}) async => warmed.add((card.id, item.title ?? '', clip));
      return warmed;
    }

    Iterable<String> artQueued(ReelController c) =>
        c.prefetcher.queued.where((t) => t.stage == ReelPrefetchStage.art).map((t) => t.cardId);

    test('+1 and +2, after their clip and text, once the card on screen shows a frame', () async {
      final c = make(decks: deckOf(5));
      final warmed = warmOn(c);
      await c.start();
      await pumpEventQueue();
      expect(warmed, isEmpty, reason: 'the lookahead waits for the first frame');
      expect(artQueued(c), ['t2', 't3'], reason: 'never the card on screen or the one behind');

      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(warmed, [('t2', 'Title 2', true), ('t3', 'Title 3', true)]);
      c.dispose();
    });

    test('each card is warmed once: a step on warms only the new +2', () async {
      final c = make(decks: deckOf(5));
      final warmed = warmOn(c);
      await c.start();
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      warmed.clear();

      await c.step(1);
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(warmed.map((w) => w.$1), ['t4']);
      c.dispose();
    });

    test('an AI card is warmed as one: the TV gives it the full backdrop', () async {
      final c = make(decks: deckOf(4), servers: _BareServers({'3'}));
      final warmed = warmOn(c);
      await c.start();
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(warmed, [('t2', 'Title 2', true), ('t3', 'Title 3', false)]);
      c.dispose();
    });

    test('nothing is warmed under memory pressure', () async {
      final c = make(decks: deckOf(4));
      final warmed = warmOn(c);
      await c.start();
      await pumpEventQueue();
      await c.trimMemory();
      expect(artQueued(c), isEmpty);
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(warmed, isEmpty);
      c.dispose();
    });

    test('with no view to build the art, no art task is queued', () async {
      final c = make(decks: deckOf(4));
      await c.start();
      await pumpEventQueue();
      expect(artQueued(c), isEmpty);
      c.dispose();
    });

    test('suspend forgets what was warmed: the art is evicted, so the next visit warms it again', () async {
      final c = make(decks: deckOf(4));
      final warmed = warmOn(c);
      await c.start();
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(warmed, hasLength(2));

      await c.suspend();
      warmed.clear();
      await c.start();
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(warmed.map((w) => w.$1), ['t2', 't3']);
      c.dispose();
    });

    test('a warm that fails is tried again on the next window', () async {
      final c = make(decks: deckOf(5));
      var fail = true;
      final warmed = <String>[];
      c.artPrecache = (card, item, {required clip}) async {
        if (fail && card.id == 't3') throw StateError('decode failed');
        warmed.add(card.id);
      };
      await c.start();
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(warmed, ['t2']);

      fail = false;
      await c.step(1);
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(warmed, ['t2', 't3', 't4'], reason: 't3 is +1 now and is warmed again');
      c.dispose();
    });

    test('Watch: an art task still waiting on its card\'s text fetches nothing after it', () async {
      final media = _GatedMedia('2');
      final c = make(decks: deckOf(4), media: media, onWatch: (_, {required onTv}) async => true);
      final warmed = warmOn(c);
      await c.start();
      engine.firstFrameCtl.add(null);
      await pumpEventQueue();
      expect(c.prefetcher.running.map((t) => t.key), contains('t2/art'), reason: "waiting on t2's text");

      await c.watch();
      media.gate.complete();
      await pumpEventQueue();
      expect(warmed, isEmpty);
      c.dispose();
    });

    test('the phone feed warms ahead at once: it has no clip core to wait for', () async {
      final c = make(decks: deckOf(4), externalClips: true);
      final warmed = warmOn(c);
      await c.start();
      await pumpEventQueue();
      expect(warmed.map((w) => w.$1), ['t2', 't3']);
      c.dispose();
    });
  });

  group('the 1-in-6 AI-card cap', () {
    Future<void> miss(List<String> ids) async {
      for (final id in ids) {
        await store.cache('src:g$id', ClipResolver.missRow);
      }
    }

    test('cached misses are AI cards when the deck is built; titles not resolved yet count as clips', () async {
      await miss(['1', '2']);
      final c = make(
        externalClips: true,
        decks: [
          _ArrangedDeck('a', [for (var i = 1; i <= 8; i++) _card('$i')]),
        ],
      );
      await c.start();
      expect(c.cards?.map((x) => x.id), ['t1', 't3', 't4', 't5', 't6', 't7', 't2', 't8']);
      await pumpEventQueue();
      c.dispose();
    });

    test('a raw deck keeps its own order whatever the cache says', () async {
      await miss(['1', '2']);
      final c = make(
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3')]),
        ],
        externalClips: true,
      );
      await c.start();
      expect(c.cards?.map((x) => x.id), ['t1', 't2', 't3']);
      await pumpEventQueue();
      c.dispose();
    });

    test('the phone holds back an AI card ahead with no room, before it comes on screen', () async {
      await miss(['1', '2', '4']);
      final c = make(
        externalClips: true,
        decks: [
          _Deck('a', [for (var i = 1; i <= 5; i++) _card('$i')]),
        ],
      );
      await c.start();
      await pumpEventQueue();
      expect(c.current.card?.id, 't1');
      expect(c.current.isAiCard, isTrue);
      expect(c.cards?.map((x) => x.id), ['t1', 't3', 't5']);
      expect(c.index, 0);
      c.dispose();
    });

    test('an AI card ahead with room stays in the phone feed', () async {
      await miss(['2']);
      final c = make(
        externalClips: true,
        decks: [
          _Deck('a', [_card('1'), _card('2'), _card('3')]),
        ],
      );
      await c.start();
      await pumpEventQueue();
      expect(c.cards?.map((x) => x.id), ['t1', 't2', 't3']);
      await c.step(1);
      expect(c.current.card?.id, 't2');
      expect(c.current.isAiCard, isTrue);
      c.dispose();
    });
  });

  group('deck switch (V2-27)', () {
    test('the strip stays while a slow deck loads, and goes a hold after it shows', () async {
      final slow = _SlowDeck('b', [_card('5')])..gate = Completer<void>();
      final c = make(
        decks: [
          _Deck('a', [_card('1')]),
          slow,
        ],
      )..stripHold = const Duration(milliseconds: 60);
      await c.start();
      final switching = c.switchDeck(1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(c.current.kind, ReelSlotKind.loading);
      expect(c.deckStrip.value?.current.id, 'b', reason: 'the deck has not shown: no hold yet');
      slow.gate!.complete();
      await switching;
      expect(c.current.card?.id, 't5');
      expect(c.deckStrip.value?.current.id, 'b', reason: 'the hold starts when the deck shows');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.deckStrip.value, isNull);
      c.dispose();
    });

    test("the old deck's card still opening when the deck changes never starts the hold", () async {
      final media = _GatedMedia('2');
      final slow = _SlowDeck('b', [_card('5')])..gate = Completer<void>();
      final c = make(
        media: media,
        decks: [
          _Deck('a', [_card('1'), _card('2')]),
          slow,
        ],
      )..stripHold = const Duration(milliseconds: 60);
      await c.start();
      // ↓ onto a card whose metadata is slow, then → before it shows.
      final stepping = c.step(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final switching = c.switchDeck(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      media.gate.complete();
      await stepping;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.deckStrip.value?.current.id, 'b', reason: 'deck b has not shown yet');
      slow.gate!.complete();
      await switching;
      expect(c.current.card?.id, 't5');
      expect(c.deckStrip.value?.current.id, 'b');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.deckStrip.value, isNull);
      c.dispose();
    });

    test('the strip names the decks either side', () async {
      final c = make(
        decks: [
          _Deck('a', [_card('1')]),
          _Deck('b', [_card('2')]),
          _Deck('c', [_card('3')]),
        ],
      );
      await c.start();
      await c.switchDeck(1);
      final strip = c.deckStrip.value!;
      expect([strip.previous?.id, strip.current.id, strip.next?.id], ['a', 'b', 'c']);
      await c.switchDeck(1);
      final wrapped = c.deckStrip.value!;
      expect([wrapped.previous?.id, wrapped.current.id, wrapped.next?.id], ['b', 'c', 'a']);
      c.dispose();
    });

    test('with two decks the strip shows only the next one', () async {
      final c = make(
        decks: [
          _Deck('a', [_card('1')]),
          _Deck('b', [_card('2')]),
        ],
      );
      await c.start();
      await c.switchDeck(1);
      expect(c.deckStrip.value?.previous, isNull);
      expect(c.deckStrip.value?.next?.id, 'a');
      c.dispose();
    });

    test('leaving the Reel takes the strip down', () async {
      final c = make(
        decks: [
          _Deck('a', [_card('1')]),
          _Deck('b', [_card('2')]),
        ],
      );
      await c.start();
      await c.switchDeck(1);
      expect(c.deckStrip.value, isNotNull);
      await c.suspend();
      expect(c.deckStrip.value, isNull);
      c.dispose();
    });

    test('a deck that fails to load says so, and OK loads it again', () async {
      final flaky = _SlowDeck('b', [_card('5')])..fails = true;
      final c = make(
        decks: [
          _Deck('a', [_card('1')]),
          flaky,
        ],
      );
      await c.start();
      await c.switchDeck(1);
      expect(c.current.kind, ReelSlotKind.failed, reason: 'not an empty deck');
      expect(c.cards, isNull);

      flaky
        ..fails = false
        ..gate = Completer<void>();
      final retry = c.retryDeck();
      await Future<void>.delayed(Duration.zero);
      expect(c.current.kind, ReelSlotKind.loading, reason: 'the skeleton while it tries again');
      flaky.gate!.complete();
      await retry;
      expect(flaky.loads, 2);
      expect(c.current.card?.id, 't5');
      c.dispose();
    });

    test('a failed deck loads again when it is next visited', () async {
      final flaky = _SlowDeck('b', [_card('5')])..fails = true;
      final c = make(
        decks: [
          _Deck('a', [_card('1')]),
          flaky,
        ],
      );
      await c.start();
      await c.switchDeck(1);
      expect(c.current.kind, ReelSlotKind.failed);
      await c.switchDeck(1);
      flaky.fails = false;
      await c.switchDeck(1);
      expect(c.current.card?.id, 't5');
      c.dispose();
    });

    test('retry does nothing on a deck that loaded', () async {
      var loads = 0;
      final c = make(
        decks: [
          _CountingDeck('a', [_card('1')], () => loads++),
        ],
      );
      await c.start();
      await c.retryDeck();
      expect(loads, 1);
      c.dispose();
    });
  });
  group('when a clip ends: Lean back on the TV (V2-47)', () {
    late DateTime now;

    String clipOf(String ratingKey) => 'open https://s1.example/services/iva/assets/$ratingKey/video.mp4';

    /// The clip on screen shows its first frame and plays out once; then
    /// the outgoing clip's 250 ms fade runs, so the next one is open.
    Future<void> playOut() async {
      engine.firstFrameCtl.add(null);
      engine.completedCtl.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

    setUp(() => now = DateTime(2026, 3, 2, 20));

    ReelController lean({ReelServers? servers, ReelClipEnd end = ReelClipEnd.nextCard}) => make(
      clock: () => now,
      servers: servers,
      plays: () => end.plays,
      clipEnd: () => end,
      decks: [
        _Deck('a', [_card('1'), _card('2'), _card('3'), _card('4')]),
      ],
    );

    test('the clip-end prefs map to plays: loop for good, twice, once', () {
      expect(ReelClipEnd.loop.plays, isNull);
      expect(ReelClipEnd.twiceThenHold.plays, 2);
      expect(ReelClipEnd.nextCard.plays, 1);
    });

    test('next card moves on once the clip has played, and records it as watched to the end', () async {
      final c = lean();
      await c.start();
      await pumpEventQueue();
      expect(c.current.card?.id, 't1');
      await playOut();
      expect(c.current.card?.id, 't2');
      expect(engine.calls, contains(clipOf('2')));
      final events = await store.events(since: DateTime(2000));
      expect(events.where((e) => e.titleId == 't1').map((e) => e.action), contains(ReelAction.toEnd.name));
      c.dispose();
    });

    test('Lean back passes over AI cards, which have no end to move on from', () async {
      final c = lean(servers: _SomeServers({'2', '3'}));
      await c.start();
      await pumpEventQueue();
      await playOut();
      expect(c.current.card?.id, 't4');
      expect(c.current.clip, isNotNull);
      c.dispose();
    });

    test('a key press still shows an AI card', () async {
      final c = lean(servers: _SomeServers({'2'}));
      await c.start();
      await pumpEventQueue();
      await c.step(1);
      expect(c.current.card?.id, 't2');
      expect(c.current.isAiCard, isTrue);
      c.dispose();
    });

    test('after 30 minutes with no input it holds instead; input lets it roll on again', () async {
      final c = lean();
      await c.start();
      await pumpEventQueue();
      expect(c.mayRollOn, isTrue);
      await playOut();
      expect(c.current.card?.id, 't2');

      // Cards moving on by themselves are not input.
      now = now.add(ReelController.leanBackIdle);
      expect(c.mayRollOn, isFalse);
      await playOut();
      expect(c.current.card?.id, 't2');
      expect(c.clips.phase.value, ClipPhase.held);

      c.noteInput();
      expect(c.mayRollOn, isTrue);
      await c.replay();
      await playOut();
      expect(c.current.card?.id, 't3');
      c.dispose();
    });

    test('twice then hold never moves on by itself', () async {
      final c = lean(end: ReelClipEnd.twiceThenHold);
      await c.start();
      await pumpEventQueue();
      await playOut();
      expect(c.clips.phase.value, ClipPhase.playing, reason: 'the second play');
      engine.completedCtl.add(true);
      await pumpEventQueue();
      expect(c.clips.phase.value, ClipPhase.held);
      expect(c.current.card?.id, 't1');
      c.dispose();
    });

    test('the phone feed moves on itself: a held card never steps the controller', () async {
      final c = make(externalClips: true, clipEnd: () => ReelClipEnd.nextCard, clock: () => now);
      await c.start();
      c.clipStarted('t1');
      c.clipEnded();
      await pumpEventQueue();
      expect(c.current.card?.id, 't1');
      c.dispose();
    });
  });

  group('deck order, hidden decks and the start deck (V2-52)', () {
    List<ReelDeck> four() => [
      _Deck('for-you', [_card('1')]),
      _Deck('anime-openings', [_card('2')]),
      _Deck('most-watched', [_card('3')]),
      _Deck('ai:7', [_card('4')]),
    ];
    List<String> ids(List<ReelDeck> d) => [for (final x in d) x.id];

    test('with nothing arranged the Reel opens on For You and offers every deck in the app order', () async {
      final decks = four()..insert(0, decks0());
      final c = make(decks: decks);
      await c.start();
      expect(c.deck.id, 'for-you', reason: 'For You is the start deck even when it is not first');
      expect(ids(c.shownDecks), ['other', 'for-you', 'anime-openings', 'most-watched', 'ai:7']);
      expect(built, isEmpty, reason: 'For You is looked up, never built');
      c.dispose();
    });

    test('the user order and hidden decks drive the pickers, → and the On TV state', () async {
      await store.writeDeckPrefs(
        const ReelDeckPrefs(order: ['ai:7', 'for-you'], hidden: {'most-watched'}),
        was: ReelDeckPrefs.none,
      );
      final c = make(decks: four());
      await c.start();
      expect(c.deck.id, 'for-you');
      expect(ids(c.shownDecks), ['ai:7', 'for-you', 'anime-openings']);
      expect(c.nextDeck?.id, 'anime-openings');
      await c.switchDeck(1);
      expect(c.deck.id, 'anime-openings');
      await c.switchDeck(1);
      expect(c.deck.id, 'ai:7', reason: 'the hidden deck is skipped and the cycle wraps');
      expect(
        [for (final d in c.remoteState()['decks']! as List) (d as Map)['id']],
        ['ai:7', 'for-you', 'anime-openings'],
      );
      c.dispose();
    });

    test('a link still opens a hidden deck; it stays ticked while playing and → leaves it for its neighbour', () async {
      await store.writeDeckPrefs(const ReelDeckPrefs(hidden: {'most-watched'}), was: ReelDeckPrefs.none);
      final c = make(decks: four());
      await c.start(deckId: 'most-watched');
      expect(c.deck.id, 'most-watched');
      expect(ids(c.shownDecks), ['for-you', 'anime-openings', 'most-watched', 'ai:7']);
      await c.switchDeck(1);
      expect(c.deck.id, 'ai:7');
      expect(ids(c.shownDecks), ['for-you', 'anime-openings', 'ai:7']);
      await c.openDeck('most-watched');
      expect(c.deck.id, 'most-watched');
      c.dispose();
    });

    test('"Where I left off" opens the deck this device was last on', () async {
      final first = make(decks: four());
      await first.start();
      await first.switchDeck(1);
      expect(first.deck.id, 'anime-openings');
      await pumpEventQueue();
      first.dispose();

      await store.writeDeckPrefs(const ReelDeckPrefs(start: ReelStartDeck.last), was: ReelDeckPrefs.none);
      final last = make(decks: four());
      await last.start();
      expect(last.deck.id, 'anime-openings');
      last.dispose();

      await store.writeDeckPrefs(ReelDeckPrefs.none, was: const ReelDeckPrefs(start: ReelStartDeck.last));
      final forYou = make(decks: four());
      await forYou.start();
      expect(forYou.deck.id, 'for-you', reason: 'For You starts For You, wherever this device left off');
      forYou.dispose();
    });

    test('a hidden start deck gives way to the first shown deck', () async {
      await store.writeDeckPrefs(
        const ReelDeckPrefs(order: ['anime-openings'], hidden: {'for-you'}),
        was: ReelDeckPrefs.none,
      );
      final c = make(decks: four());
      await c.start();
      expect(c.deck.id, 'anime-openings');
      c.dispose();
    });

    test('coming back to a warm Reel keeps the deck that was playing', () async {
      final c = make(decks: four());
      await c.start();
      await c.switchDeck(1);
      await c.suspend();
      await c.start();
      expect(c.deck.id, 'anime-openings');
      c.dispose();
    });

    test('moving and hiding from a picker is kept, synced, and shown at once', () async {
      final c = make(decks: four());
      await c.start();
      var notified = 0;
      c.addListener(() => notified++);
      await c.moveDeck('ai:7', -99);
      expect(ids(c.shownDecks), ['ai:7', 'for-you', 'anime-openings', 'most-watched']);
      await c.moveDeck('for-you', 1);
      expect(ids(c.shownDecks), ['ai:7', 'anime-openings', 'for-you', 'most-watched']);
      await c.hideDeck('most-watched', hide: true);
      expect(ids(c.shownDecks), ['ai:7', 'anime-openings', 'for-you']);
      expect(notified, greaterThanOrEqualTo(3));
      final stored = await store.deckPrefs();
      expect(stored.order.take(3), ['ai:7', 'anime-openings', 'for-you']);
      expect(stored.hidden, {'most-watched'});

      await c.hideDeck('most-watched', hide: false);
      expect(ids(c.shownDecks), contains('most-watched'));
      c.dispose();
    });

    test('the last shown deck is never hidden', () async {
      final c = make(
        decks: [
          _Deck('for-you', [_card('1')]),
          _Deck('ai:7', [_card('4')]),
        ],
      );
      await c.start();
      await c.hideDeck('ai:7', hide: true);
      await c.hideDeck('for-you', hide: true);
      expect(c.deckPrefs.hidden, {'ai:7'});
      expect(ids(c.shownDecks), ['for-you']);
      c.dispose();
    });

    test('an arrangement made elsewhere (the Decks screen, the other device) is taken up at once', () async {
      final changed = ValueNotifier(0);
      final c = make(decks: four(), deckPrefsChanged: changed);
      await c.start();
      await store.writeDeckPrefs(const ReelDeckPrefs(hidden: {'anime-openings'}), was: ReelDeckPrefs.none);
      changed.value++;
      await pumpEventQueue();
      expect(ids(c.shownDecks), ['for-you', 'most-watched', 'ai:7']);
      c.dispose();
    });

    test('on a mirror that lost its TV an arrangement is not kept, and it says so', () async {
      store = ReelStore(
        database: () async => db,
        settings: () async => MirrorCustomisationStore({}, send: (_) => false),
      );
      final c = make(decks: four());
      await c.start();
      await expectLater(c.moveDeck('ai:7', -1), completes);
      expect(ids(c.shownDecks), ['for-you', 'anime-openings', 'most-watched', 'ai:7']);
      expect(c.toast.value, ReelController.notConnected);
      c.dispose();
    });
  });
}

ReelDeck decks0() => _Deck('other', [_card('8')]);
