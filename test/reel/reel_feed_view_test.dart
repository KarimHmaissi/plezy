import 'dart:async';

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
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/theme/mono_motion.dart';

import 'clip_player_test.dart' show FakeClipEngine;

class _Servers implements ReelServers {
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => [
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
  /// When set, items wait for it (V2-26: metadata that lands late).
  Completer<void>? gate;

  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async {
    await gate?.future;
    return MediaItem(
      id: ratingKey,
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Title $ratingKey',
      year: 2020,
      contentRating: 'PG',
    );
  }

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
  @override
  Future<List<ReelCardData>> load() async => [for (final i in ids) _card(i)];
}

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
    summary: '',
  ),
  why: 'Like the films you finish.',
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
  late _Media media;

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    final store = ReelStore(database: () async => db, settings: () async => settings);
    opened = [];
    decksOpened = watched = sheets = 0;
    restored = ValueNotifier(0);
    c = ReelController(
      decks: [
        first = _Deck('a', ['1', '2', '3', '4']),
        _Deck('b', ['9']),
      ],
      resolver: ClipResolver(
        servers: _Servers(),
        store: store,
        aniList: (_) async => null,
        animeThemes: (_) async => const {},
      ),
      clips: ClipPlayer(engine: FakeClipEngine.new),
      store: store,
      media: media = _Media(),
      onWatch: (_, {required onTv}) async => true,
      addToWatchlist: (_) async => true,
      externalClips: true,
      memoryRestored: restored,
      onOpen: (item) async => opened.add(item),
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
  group('metadata landing late (V2-26)', () {
    /// The feed with every item held back until the gate opens.
    Future<void> pumpGated(WidgetTester tester, {bool reduceMotion = false}) async {
      media.gate = Completer<void>();
      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        unawaited(c.start());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
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
      await tester.pump();
      expect(c.current.kind, ReelSlotKind.card);
      expect(c.current.item, isNull);
    }

    Future<void> land(WidgetTester tester) async {
      media.gate!.complete();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(c.current.item, isNotNull);
      await tester.pump();
    }

    Finder line() => find.byType(ReelMetadataLine).first;

    testWidgets('the title stays put: the facts line keeps its height and the block grows by gliding', (tester) async {
      await pumpGated(tester);
      Finder block() => find.ancestor(of: find.text('Title 1'), matching: find.byType(AnimatedSize)).first;
      final lineHeight = tester.getSize(line()).height;
      expect(lineHeight, greaterThan(0), reason: 'the line is reserved before anything is known');
      expect(find.text('PG'), findsNothing);
      final title = tester.getRect(find.text('Title 1'));
      final blockTop = tester.getRect(block()).top;

      final grow = tester.widget<AnimatedSize>(block());
      expect(grow.alignment, Alignment.bottomLeft);
      expect(grow.duration, const Duration(milliseconds: 200));
      expect(grow.curve, MonoMotion.standard);

      await land(tester);
      expect(find.text('PG'), findsOneWidget);
      expect(tester.getRect(find.text('Title 1')).topLeft, title.topLeft);
      // The clip chip arrives above the title: the block's top glides up.
      await tester.pump(const Duration(milliseconds: 80));
      final mid = tester.getRect(block()).top;
      expect(tester.getRect(find.text('Title 1')).topLeft, title.topLeft);
      await tester.pumpAndSettle();
      final settled = tester.getRect(block()).top;
      expect(settled, lessThan(blockTop));
      expect(mid, lessThan(blockTop));
      expect(mid, greaterThan(settled), reason: 'part of the way, not a jump');
      expect(tester.getRect(find.text('Title 1')).topLeft, title.topLeft);
      expect(tester.getSize(line()).height, closeTo(lineHeight, 0.5));
    });

    testWidgets('with animations off the block changes at once', (tester) async {
      await pumpGated(tester, reduceMotion: true);
      expect(find.ancestor(of: find.text('Title 1'), matching: find.byType(AnimatedSize)), findsNothing);
      await land(tester);
      await tester.pump();
      expect(find.text('PG'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('ReelMetadataLine is one line tall before anything is known (V2-26)', (tester) async {
    Future<double> heightOf(Widget line) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Align(alignment: Alignment.topLeft, child: line),
        ),
      );
      return tester.getSize(find.byType(ReelMetadataLine)).height;
    }

    final empty = await heightOf(const ReelMetadataLine(item: null, fontSize: 14));
    final year = await heightOf(const ReelMetadataLine(item: null, year: 2020, fontSize: 14));
    expect(empty, greaterThan(0));
    expect(empty, closeTo(year, 0.5));
  });
}
