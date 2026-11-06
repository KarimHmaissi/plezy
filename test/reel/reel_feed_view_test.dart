import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/reel/reel_card_view.dart';
import 'package:plezy/screens/reel/reel_feed_view.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/memory_trim_policy.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/feed_players.dart';
import 'package:plezy/services/reel/reel_art.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/media_image_helper.dart';
import 'package:plezy/widgets/cycling_media_backdrop.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:plezy/widgets/tv_spotlight_background.dart';

import '../test_helpers/prefs.dart';
import 'clip_player_test.dart' show FakeClipEngine;

class _Servers implements ReelServers {
  /// Titles with no extras: they end as AI cards.
  final Set<String> bare = {};

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => [
    if (!bare.contains(ratingKey))
      PlexExtraClip(
        ratingKey: 'x$ratingKey',
        title: 'Trailer',
        partKey: '/iva/$ratingKey.mp4',
        subtype: 'trailer',
        index: 0,
      ),
  ];

  @override
  String? clipUrl(String serverId, String partKey) => 'https://cdn.example$partKey';
}

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async => MediaItem(
    id: ratingKey,
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Title $ratingKey',
    year: 2020,
  );

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) => item(serverId, ratingKey);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

class _Deck extends ReelDeck {
  _Deck(this.id, this.ids);

  @override
  final String id;
  List<String> ids;

  /// Today's build landing.
  @override
  final ValueNotifier<int> rebuilt = ValueNotifier(0);

  @override
  String get name => 'Deck $id';
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;

  /// Cards built with a hook or a seen state of their own.
  final Map<String, ReelCardData> special = {};

  @override
  Future<List<ReelCardData>> load() async => [for (final i in ids) special[i] ?? _card(i)];
}

ReelCardData _card(String id, {String? hook, SeenState seen = SeenState.unseen, bool resume = false}) => ReelCardData(
  title: ReelTitle(
    titleId: 't$id',
    groupKey: 'g$id',
    title: 'Title $id',
    isShow: false,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: 't$id', groupKey: 'g$id'),
    seen: seen,
  ),
  best: IndexedTitle(
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
    summary: 'A keeper relights the harbor lamp. The town learns why it went dark.',
  ),
  why: 'Like the films you finish.',
  hook: hook,
  resume: resume,
);

/// A player that is ready as soon as it opens.
class _Video extends ChangeNotifier implements FeedVideo {
  bool _ready = false, _playing = false;
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
  bool get playing => _playing;
  @override
  Future<void> initialize() async => _ready = true;
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async => super.dispose();
  @override
  Widget view() => const ColoredBox(color: Colors.teal);
}

void main() {
  late ForkDatabase db;
  late ReelController c;
  late ReelFeedPlayers players;
  late List<MediaItem> opened;
  late int decksOpened, watched, sheets;
  late ValueNotifier<int> restored;
  late _Deck first;
  late _Servers servers;
  late ReelStore store;

  setUp(() {
    ReelArt.resetForTesting();
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    opened = [];
    decksOpened = watched = sheets = 0;
    restored = ValueNotifier(0);
    c = ReelController(
      decks: [
        first = _Deck('a', ['1', '2', '3', '4']),
        _Deck('b', ['9']),
      ],
      resolver: ClipResolver(
        servers: servers = _Servers(),
        store: store,
        aniList: (_) async => null,
        animeThemes: (_) async => const {},
      ),
      clips: ClipPlayer(engine: FakeClipEngine.new),
      store: store,
      media: _Media(),
      onWatch: (_, {required onTv}) async => true,
      addToWatchlist: (_) async => true,
      externalClips: true,
      memoryRestored: restored,
      onOpen: (item) async => opened.add(item),
      moreLike: (seed, {required skip}) async => [_card('5'), _card('6')],
      // A resume card's show has its fourth episode on deck.
      itemWithNext: (serverId, ratingKey) async => (
        item: await _Media().item(serverId, ratingKey),
        next: MediaItem.plex(
          id: 'e$ratingKey',
          kind: MediaKind.episode,
          title: 'Harbor Lights 4',
          parentIndex: 1,
          index: 4,
        ),
      ),
    );
    players = ReelFeedPlayers(create: (_) => _Video());
  });

  tearDown(() async {
    c.dispose();
    players.dispose();
    restored.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(c.start);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ReelFeedView(
            controller: c,
            players: players,
            watchOnTv: false,
            onWatch: () => watched++,
            onSheet: () => sheets++,
            onDecks: () => decksOpened++,
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  bool hidden(WidgetTester tester, String text) => tester
      .widgetList<IgnorePointer>(find.ancestor(of: find.text(text), matching: find.byType(IgnorePointer)))
      .any((w) => w.ignoring);

  testWidgets('the card shows its title, why line and the two primary controls', (tester) async {
    await pump(tester);
    expect(find.text('Title 1'), findsOneWidget);
    expect(find.text('Like the films you finish.'), findsWidgets);
    expect(find.text('Watch'), findsWidgets);
    expect(find.text('Details'), findsWidgets);
    expect(find.text('Deck a'), findsOneWidget);
  });

  testWidgets('the card on screen plays and the next one is already open', (tester) async {
    await pump(tester);
    expect(players.current, 't1');
    expect(players.held, containsAll(['t1', 't2']));
  });

  testWidgets('a halved watchdog tick shrinks the feed to the card on screen until restore', (tester) async {
    await pump(tester);
    expect(players.held, containsAll(['t1', 't2']));
    await tester.runAsync(() => c.trimForWatchdog(WatchdogTrim.halved));
    await tester.pump();
    expect(players.held, ['t1']);
    expect(players.current, 't1');

    restored.value++;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(players.held, containsAll(['t1', 't2']));
  });

  testWidgets('a cleared watchdog tick leaves the feed on stills', (tester) async {
    await pump(tester);
    await tester.runAsync(() => c.trimForWatchdog(WatchdogTrim.cleared));
    await tester.pump();
    expect(players.held, isEmpty);
    expect(find.text('Title 1'), findsOneWidget);
  });

  testWidgets('swiping up moves to the next card and its parked player', (tester) async {
    await pump(tester);
    await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(c.current.card?.id, 't2');
    expect(players.current, 't2');
  });

  testWidgets("today's build landing keeps the page on screen and follows it", (tester) async {
    await pump(tester);
    await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(c.index, 1);

    first.ids = ['7', '8'];
    first.rebuilt.value++;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(c.index, 1);
    expect(c.current.card?.id, 't2');
    expect(find.text('Title 2'), findsOneWidget);
    expect(players.current, 't2');
    expect(players.held, contains('t7'), reason: 'the new next card is parked');

    await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(c.current.card?.id, 't7');
    expect(players.current, 't7');
  });

  testWidgets('More like this inserts after the page on screen: the page stays, the new next card is parked', (
    tester,
  ) async {
    await pump(tester);
    await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(c.current.card?.id, 't2');

    final press = c.moreLikeThis();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await tester.runAsync(() => press);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(c.index, 1);
    expect(c.current.card?.id, 't2');
    expect(find.text('Title 2'), findsOneWidget);
    expect(players.current, 't2');
    expect(players.held, contains('t5'), reason: 'the first new card is parked next');

    await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(c.current.card?.id, 't5');
    expect(players.current, 't5');
    // The confirmation's own timer runs out.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets("Tonight's picks after the second Save: the page stays, then a swipe brings it up", (tester) async {
    Future<void> fling() async {
      await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    await pump(tester);
    await tester.runAsync(c.save);
    await fling();
    expect(c.current.card?.id, 't2');
    await tester.runAsync(c.save);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(c.page, 1, reason: 'placing it ahead never moves the page on screen');
    expect(find.text('Title 2'), findsWidgets);
    expect(players.current, 't2');

    await fling();
    expect(c.current.kind, ReelSlotKind.decide);
    expect(find.text("Tonight's picks"), findsOneWidget);
    expect(find.text('One for tonight?'), findsOneWidget);
    expect(players.current, isNull, reason: 'nothing plays under it');
    final chosen = find.byKey(const ValueKey('decide:chosen'));
    expect(tester.widget<Text>(chosen).data, 'Title 2', reason: 'the newest Save is chosen first');

    await tester.tap(find.byKey(const ValueKey('decide:t1')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(chosen).data, 'Title 1');
    expect(c.current.chosen?.pick.titleId, 't1');
    await tester.tap(find.widgetWithText(FilledButton, 'Watch'));
    expect(watched, 1);

    await fling();
    expect(c.current.card?.id, 't3');
    expect(players.current, 't3');
    // The confirmations' own timers run out.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('swipe right hides the controls to watch; swipe left brings them back', (tester) async {
    await pump(tester);
    expect(hidden(tester, 'Details'), isFalse);
    await tester.fling(find.text('Title 1'), const Offset(300, 0), 1500);
    await tester.pumpAndSettle();
    expect(hidden(tester, 'Details'), isTrue);
    expect(hidden(tester, 'Deck a'), isTrue);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(hidden(tester, 'Details'), isFalse);
    expect(c.deck.id, 'a', reason: 'a sideways swipe never changes the deck');
  });

  testWidgets('the deck is picked from its own button', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Deck a'));
    expect(decksOpened, 1);
  });

  testWidgets('Details opens the title page; Watch hands over', (tester) async {
    await pump(tester);
    // The handler writes the event through drift, which needs real async.
    await tester.runAsync(() async {
      await tester.tap(find.text('Details').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(opened.single.id, '1');
    await tester.tap(find.text('Watch').first);
    expect(watched, 1);
  });

  testWidgets('the still under the clip sizes from its frame, not a fixed 960 px', (tester) async {
    await pump(tester);
    final stills = [
      for (final a in tester.widgetList<OptimizedMediaImage>(find.byType(OptimizedMediaImage)))
        if (a.width != 36) a,
    ];
    expect(stills, isNotEmpty);
    for (final still in stills) {
      // No explicit size: OptimizedMediaImage decodes at its constraints,
      // the card's 16:9 frame, where 960 x DPR hit the 1920x1080 cap.
      expect((still.width, still.height), (null, null));
      expect(still.imageType, ImageType.art);
      expect(still.onImageProvider, ReelArt.track, reason: "the Reel's art is let go on suspend");
      final size = tester.getSize(find.byWidget(still));
      expect(size.width, lessThanOrEqualTo(420));
      expect(size.height, moreOrLessEquals(size.width * 9 / 16, epsilon: 1));
      // The frame the next cards' art is warmed at (V2-13).
      expect(size, reelStillFrame(tester.getSize(find.byType(ReelFeedView)), 16 / 9));
    }
  });

  testWidgets('the feed warms the next cards\' art while it is mounted (V2-13)', (tester) async {
    await pump(tester);
    expect(c.artPrecache, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(c.artPrecache, isNull, reason: 'a feed that has gone builds no art');
  });

  group('TV card art', () {
    Future<void> pumpCard(WidgetTester tester) async {
      resetSharedPreferencesForTest();
      await tester.runAsync(SettingsService.getInstance);
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(c.start);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: ReelCardView(controller: c, slot: c.current, tv: true, onReplay: () {}),
          ),
        ),
      );
      await tester.pump();
    }

    TvSpotlightBackground spotlight(WidgetTester tester) =>
        tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground));

    testWidgets('a clip card decodes its art at the thumbnail cap', (tester) async {
      await pumpCard(tester);
      expect(c.current.clip, isNotNull);
      expect(spotlight(tester).lightArt, isTrue);
      expect(tester.widget<CyclingMediaBackdrop>(find.byType(CyclingMediaBackdrop)).imageType, ImageType.thumb);
      expect(spotlight(tester).onArtProvider, ReelArt.track);
    });

    testWidgets('an AI card keeps the full backdrop', (tester) async {
      servers.bare.add('1');
      await pumpCard(tester);
      expect(c.current.isAiCard, isTrue);
      expect(spotlight(tester).lightArt, isFalse);
      expect(tester.widget<CyclingMediaBackdrop>(find.byType(CyclingMediaBackdrop)).imageType, ImageType.art);
    });
  });

  group('what a card is about', () {
    const premise = 'A keeper relights the harbor lamp.';

    testWidgets('a card with no clip shows the first sentence of its summary', (tester) async {
      await tester.runAsync(() => store.cache('src:g1', ClipResolver.missRow));
      await pump(tester);
      await tester.pumpAndSettle();
      expect(c.current.isAiCard, isTrue);
      expect(find.text(premise), findsOneWidget);
      expect(find.textContaining('learns why'), findsNothing, reason: 'the first sentence only');
    });

    testWidgets("a trailer card doesn't: the trailer tells you", (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();
      expect(c.current.clip, isNotNull);
      expect(find.text(premise), findsNothing);
    });

    testWidgets("the daily build's hook comes before the summary", (tester) async {
      first.special['1'] = _card('1', hook: 'A lamp, a harbor and one long night');
      await tester.runAsync(() => store.cache('src:g1', ClipResolver.missRow));
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.text('A lamp, a harbor and one long night'), findsOneWidget);
      expect(find.text(premise), findsNothing);
    });

    testWidgets('a Give it another go card reads Resume with its next episode', (tester) async {
      first.special['1'] = _card('1', seen: const SeenState(kind: SeenKind.paused, eps: 3, total: 10), resume: true);
      await pump(tester);
      expect(find.text('Resume E4'), findsOneWidget);
      expect(find.text('Started'), findsOneWidget);
    });

    testWidgets('a deck that keeps seen titles shows the seen badge', (tester) async {
      first.special['1'] = _card('1', seen: const SeenState(kind: SeenKind.finished, eps: 10, total: 10));
      await pump(tester);
      expect(find.text('Seen'), findsOneWidget);
    });
  });
}
