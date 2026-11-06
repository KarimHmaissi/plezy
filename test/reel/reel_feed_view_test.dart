import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/theme/mono_tokens.dart';
import 'package:plezy/theme/palette_contrast.dart';
import 'package:plezy/utils/immersive_mode_guard.dart';
import 'package:plezy/widgets/overlay_sheet.dart';

import '../test_helpers/prefs.dart';
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
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async => MediaItem(
    id: ratingKey,
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Title $ratingKey',
    year: 2020,
  );

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
  Duration at = Duration.zero;
  int seeks = 0;
  @override
  bool get ready => _ready;
  @override
  bool get failed => false;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Duration get position => at;
  @override
  Duration get duration => const Duration(seconds: 60);
  @override
  bool get playing => _playing;
  @override
  Duration get buffered => _ready ? duration : Duration.zero;
  @override
  Future<void> initialize() async => _ready = true;
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> seekTo(Duration position) async {
    seeks++;
    at = position;
  }

  /// The plugin's position poll.
  void tick(Duration to) {
    at = to;
    notifyListeners();
  }

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
  late Map<String, _Video> videos;
  late ReelStore store;
  late List<MediaItem> opened;
  late int decksOpened, watched, sheets, resized;
  late List<bool> immersiveReports;
  late ValueNotifier<int> restored;
  late _Deck first;

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    opened = [];
    decksOpened = watched = sheets = resized = 0;
    immersiveReports = [];
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
      media: _Media(),
      onWatch: (_, {required onTv}) async => true,
      addToWatchlist: (_) async => true,
      externalClips: true,
      memoryRestored: restored,
      onOpen: (item) async => opened.add(item),
    );
    videos = {};
    players = ReelFeedPlayers(create: (uri) => videos[uri.pathSegments.last.split('.').first] = _Video());
  });

  tearDown(() async {
    c.dispose();
    players.dispose();
    restored.dispose();
    await db.close();
  });

  Widget feed({bool metered = false, bool watchOnTv = false}) => ReelFeedView(
    metered: metered,
    controller: c,
    players: players,
    watchOnTv: watchOnTv,
    onWatch: () => watched++,
    onSheet: () => sheets++,
    onDecks: () => decksOpened++,
    onResize: () => resized++,
    onImmersive: immersiveReports.add,
  );

  Future<void> pump(
    WidgetTester tester, {
    ThemeData? appTheme,
    MonoPalette? palette,
    bool themed = false,
    bool watchOnTv = false,
    Widget Function(Widget feed)? wrap,
  }) async {
    tester.view.physicalSize = const Size(420, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(c.start);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme ?? ThemeData.dark(),
        home: Scaffold(
          body: (wrap ?? (f) => f)(
            themed
                ? ReelFeedTheme(
                    palette: palette,
                    child: feed(watchOnTv: watchOnTv),
                  )
                : feed(watchOnTv: watchOnTv),
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

  testWidgets('on mobile data the feed parks only the next card; Wi-Fi opens the window again (V2-08)', (tester) async {
    await pump(tester);
    await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(players.held, containsAll(['t1', 't2', 't3']), reason: 'the one behind is parked too');

    Widget app(bool metered) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: feed(metered: metered)),
    );
    await tester.pumpWidget(app(true));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(players.current, 't2');
    expect(players.held.toSet(), {'t2', 't3'}, reason: 'the card on screen and the next only');

    await tester.pumpWidget(app(false));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(players.held, containsAll(['t1', 't2', 't3']));
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

  group('V2-02: a swipe commits on settle', () {
    // The players were opened under runAsync (the resolves read drift), so
    // their futures answer on the real event loop.
    Future<void> flush(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }

    Future<void> drag(WidgetTester tester, TestGesture g, double dy) async {
      for (var i = 0; i < 10; i++) {
        await g.moveBy(Offset(0, dy / 10));
        await tester.pump();
      }
      await flush(tester);
    }

    Future<TestGesture> dragPastMiddle(WidgetTester tester) async {
      final g = await tester.startGesture(tester.getCenter(find.byType(PageView)));
      await drag(tester, g, -500);
      return g;
    }

    Future<void> letGo(WidgetTester tester, TestGesture g) async {
      await g.up();
      await tester.pumpAndSettle();
      // The step writes the card left through drift, which needs real async.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    testWidgets('the next page is built before the drag reaches it', (tester) async {
      await pump(tester);
      expect(find.text('Title 2'), findsNothing, reason: 'below the fold');
      expect(find.text('Title 2', skipOffstage: false), findsOneWidget, reason: 'already built');
    });

    testWidgets('past the middle the next card plays, the one left holds its frame, and the step waits', (
      tester,
    ) async {
      await pump(tester);
      videos['1']!.at = const Duration(seconds: 5);
      final g = await dragPastMiddle(tester);
      expect(players.current, 't2', reason: 'the incoming card plays from the middle of the swipe');
      expect(videos['2']!.playing, isTrue);
      expect(videos['1']!.playing, isFalse);
      expect(videos['1']!.at, const Duration(seconds: 5), reason: 'no snap to frame 0 while half on screen');
      expect(videos['1']!.seeks, 0);
      expect(c.index, 0, reason: 'the controller hears of it at the settle');

      await letGo(tester, g);
      expect(c.index, 1);
      expect(c.current.card?.id, 't2');
      expect(players.current, 't2');
      expect(videos['1']!.at, Duration.zero, reason: 'rewound once off screen');
    });

    testWidgets('a drag that comes back leaves the card and the cursor where they were', (tester) async {
      await pump(tester);
      videos['1']!.at = const Duration(seconds: 5);
      final g = await dragPastMiddle(tester);
      expect(players.current, 't2');
      await drag(tester, g, 500);
      expect(players.current, 't1');
      expect(videos['1']!.playing, isTrue);
      expect(videos['1']!.at, const Duration(seconds: 5), reason: 'plays on from where it held');

      await letGo(tester, g);
      expect(c.index, 0);
      expect(players.current, 't1');
      expect(videos['1']!.seeks, 0);
      final events = await tester.runAsync(() => store.events(since: DateTime(2000)));
      expect(events, isEmpty, reason: 'no card was left');
    });

    double bar(WidgetTester tester) =>
        tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value!;

    testWidgets('the progress hairline runs on between position reports, and no further than a stall allows', (
      tester,
    ) async {
      await pump(tester);
      expect(videos['1']!.playing, isTrue);
      videos['1']!.tick(const Duration(seconds: 30));
      await tester.pump();
      expect(bar(tester), closeTo(0.5, 0.0001));
      await tester.pump(const Duration(milliseconds: 100));
      expect(bar(tester), greaterThan(0.5 + 0.05 / 60), reason: 'moved with no new report');
      await tester.pump(const Duration(seconds: 1));
      expect(bar(tester), closeTo(30.25 / 60, 0.0001), reason: 'a stalled clip holds the bar a quarter second on');
      videos['1']!.tick(const Duration(seconds: 30, milliseconds: 100));
      await tester.pump();
      expect(bar(tester), closeTo(30.1 / 60, 0.0001), reason: 'each report puts it back on the truth');
    });

    testWidgets('with reduce motion on the hairline steps with the reports', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
        disableAnimations: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pump(tester);
      videos['1']!.tick(const Duration(seconds: 30));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(bar(tester), closeTo(0.5, 0.0001));
    });

    testWidgets('the picture and the info each repaint on their own', (tester) async {
      await pump(tester);
      final title = find.text('Title 1');
      expect(find.ancestor(of: title, matching: find.byType(RepaintBoundary)), findsWidgets);
      final page = find.ancestor(of: title, matching: find.byType(ValueListenableBuilder<FeedCardState>));
      expect(page, findsOneWidget, reason: 'the page listens to its own card, not every player');
    });
  });

  group('V2-65: a screen switch keeps the card', () {
    // The Fold's cover screen, then its inner screen.
    const cover = Size(420, 860);
    const inner = Size(840, 760);

    Future<void> flush(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }

    Future<void> resize(WidgetTester tester, Size to) async {
      tester.view.physicalSize = to;
      await tester.pump();
      await flush(tester);
    }

    double? page(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page;

    Future<void> swipeToNext(WidgetTester tester) async {
      await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    testWidgets('at rest: same card, same cursor, and the window is synced again', (tester) async {
      await pump(tester);
      await swipeToNext(tester);
      expect(c.index, 1);
      expect(players.current, 't2');
      // Let the step's own work finish, so nothing but the resize syncs.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      // Something outside the feed stopped the card on screen.
      await videos['2']!.pause();

      await resize(tester, inner);
      expect(resized, 1);
      expect(c.index, 1);
      expect(page(tester), closeTo(1, 0.001));
      expect(find.text('Title 2'), findsOneWidget);
      expect(players.current, 't2');
      expect(videos['2']!.playing, isTrue, reason: 'the window was synced again');
      expect(players.held, containsAll(['t1', 't2', 't3']));
      for (final id in ['1', '3']) {
        expect(videos[id]!.playing, isFalse, reason: 'no sound from card $id off screen');
      }

      await resize(tester, cover);
      expect(resized, 2);
      expect(c.index, 1);
      expect(page(tester), closeTo(1, 0.001));
      expect(players.current, 't2');
    });

    testWidgets('mid-swipe: the card under the thumb keeps playing and the step still commits on the settle', (
      tester,
    ) async {
      await pump(tester);
      final g = await tester.startGesture(tester.getCenter(find.byType(PageView)));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0, -50));
        await tester.pump();
      }
      await flush(tester);
      expect(players.current, 't2');
      expect(c.index, 0);
      await videos['2']!.pause();

      await resize(tester, inner);
      expect(players.current, 't2', reason: 'the page under the thumb is still the one playing');
      expect(videos['2']!.playing, isTrue, reason: 'the window was synced again');
      expect(videos['1']!.playing, isFalse, reason: 'no sound from the card being left');
      expect(c.index, 0, reason: 'the step still waits for the settle');
      expect(page(tester), greaterThan(0.5), reason: 'the page kept its place mid-swipe');

      await g.up();
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(c.index, 1);
      expect(page(tester), closeTo(1, 0.001));
      expect(players.current, 't2');
      expect(find.text('Title 2'), findsOneWidget);
    });

    testWidgets('a feed built again opens on the controller cursor, not on stored page state', (tester) async {
      Widget under(Widget child) => MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: KeyedSubtree(key: const PageStorageKey('reel'), child: child),
        ),
      );
      tester.view.physicalSize = cover;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(c.start);
      await tester.pumpWidget(under(feed()));
      await flush(tester);
      await swipeToNext(tester);
      expect(c.index, 1);

      // The feed goes away; the cursor moves on without it (the TV, a dropped card).
      await tester.pumpWidget(under(const SizedBox.shrink()));
      await tester.runAsync(() => c.step(1));
      expect(c.index, 2);

      await tester.pumpWidget(under(feed()));
      expect(page(tester), closeTo(2, 0.001), reason: 'from its first frame');
      await flush(tester);
      expect(page(tester), closeTo(2, 0.001));
      expect(find.text('Title 3'), findsOneWidget);
      expect(players.current, 't3');
    });
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

  group('V2-31: immersive mode done properly', () {
    late List<MethodCall> platformCalls;

    setUp(() {
      platformCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          platformCalls.add(call);
          return null;
        },
      );
    });

    tearDown(() {
      ImmersiveModeGuard.resetForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    List<Object?> uiModes() => [
      for (final call in platformCalls)
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') call.arguments,
    ];

    Future<void> swipeRight(WidgetTester tester) async {
      await tester.fling(find.text('Title 1'), const Offset(300, 0), 1500);
      await tester.pumpAndSettle();
    }

    Future<void> systemShowsBars() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          SystemChannels.platform.name,
          SystemChannels.platform.codec.encodeMethodCall(const MethodCall('SystemChrome.systemUIChange', [true])),
          (_) {},
        );

    testWidgets('swipe right hides the system bars, sticky; swipe left gives them back as the player does', (
      tester,
    ) async {
      await pump(tester);
      await swipeRight(tester);
      expect(uiModes(), ['SystemUiMode.immersiveSticky']);
      expect(immersiveReports, [true]);

      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
      await tester.pumpAndSettle();
      expect(hidden(tester, 'Details'), isFalse);
      // OrientationHelper.restoreSystemUI: both overlays shown, then edge to edge.
      expect(platformCalls.map((c) => c.method), contains('SystemChrome.setEnabledSystemUIOverlays'));
      expect(uiModes(), ['SystemUiMode.immersiveSticky', 'SystemUiMode.edgeToEdge']);
      expect(immersiveReports, [true, false]);
    });

    testWidgets('a second swipe the same way changes nothing', (tester) async {
      await pump(tester);
      await swipeRight(tester);
      await swipeRight(tester);
      expect(uiModes(), ['SystemUiMode.immersiveSticky']);
      expect(immersiveReports, [true]);
    });

    testWidgets('bars a screen switch brings back are hidden again, until the controls come back', (tester) async {
      await pump(tester);
      await swipeRight(tester);
      await systemShowsBars();
      expect(uiModes(), ['SystemUiMode.immersiveSticky', 'SystemUiMode.immersiveSticky']);

      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
      await tester.pumpAndSettle();
      platformCalls.clear();
      await systemShowsBars();
      expect(uiModes(), isEmpty, reason: 'the guard let go before the bars came back');
    });

    testWidgets('Back while immersive brings the controls back and stays on the feed', (tester) async {
      await pump(tester);
      await swipeRight(tester);
      expect(hidden(tester, 'Details'), isTrue);

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(handled, isTrue);
      expect(find.byType(ReelFeedView), findsOneWidget);
      expect(hidden(tester, 'Details'), isFalse);
      expect(hidden(tester, 'Deck a'), isFalse);
      expect(uiModes().last, 'SystemUiMode.edgeToEdge');
      expect(immersiveReports, [true, false]);
    });

    testWidgets("in the shell, Back while immersive is the feed's alone", (tester) async {
      // The mobile shell: its host can't pop and steps to Home on Back
      // unless the Reel says it is immersive (main_screen.dart).
      var immersive = false;
      var shellBacks = 0;
      final reports = immersiveReports;
      await pump(
        tester,
        wrap: (feed) => OverlaySheetHost(
          canPop: false,
          onSystemBack: () {
            if (immersive) return;
            shellBacks++;
          },
          child: feed,
        ),
      );
      void track() => immersive = reports.isNotEmpty && reports.last;

      await swipeRight(tester);
      track();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      track();
      expect(shellBacks, 0, reason: 'the shell heard the feed was immersive before the feed left it');
      expect(hidden(tester, 'Details'), isFalse);
      expect(immersive, isFalse);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(shellBacks, 1, reason: 'with the controls showing, Back is the shell again');
    });

    testWidgets('put away while immersive, the feed gives the bars back and returns with its controls', (tester) async {
      await pump(tester);
      await swipeRight(tester);
      await tester.runAsync(c.suspend);
      await tester.pump();
      expect(hidden(tester, 'Details'), isFalse);
      expect(uiModes().last, 'SystemUiMode.edgeToEdge');
      expect(immersiveReports, [true, false]);
    });

    testWidgets('disposed while immersive, the feed gives the bars back', (tester) async {
      await pump(tester);
      await swipeRight(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(uiModes().last, 'SystemUiMode.edgeToEdge');
      expect(immersiveReports, [true, false]);
    });

    testWidgets('only the progress hairline stays over the picture', (tester) async {
      await pump(tester);
      await swipeRight(tester);
      expect(hidden(tester, 'Details'), isTrue);
      expect(hidden(tester, 'Deck a'), isTrue);
      final bar = find.byType(LinearProgressIndicator);
      expect(bar, findsOneWidget);
      expect(
        tester
            .widgetList<IgnorePointer>(find.ancestor(of: bar, matching: find.byType(IgnorePointer)))
            .any((w) => w.ignoring),
        isFalse,
      );
      expect(
        tester
            .widgetList<AnimatedOpacity>(find.ancestor(of: bar, matching: find.byType(AnimatedOpacity)))
            .every((w) => w.opacity == 1),
        isTrue,
      );
    });

    group('the art behind the picture', () {
      double dim(WidgetTester tester) {
        final box = tester.widget<AnimatedContainer>(
          find.descendant(of: find.byType(PageView), matching: find.byType(AnimatedContainer)).first,
        );
        return (box.decoration! as BoxDecoration).color!.a;
      }

      testWidgets('goes to black on an OLED ground', (tester) async {
        await pump(tester, themed: true, palette: MonoPalette.oled);
        expect(dim(tester), closeTo(0.55, 0.01));
        await swipeRight(tester);
        expect(dim(tester), 1.0);
      });

      testWidgets('keeps a trace of the art on any other ground', (tester) async {
        await pump(tester, themed: true, palette: MonoPalette.dark);
        await swipeRight(tester);
        expect(dim(tester), closeTo(0.9, 0.01));
      });
    });

    group('the one-time hint', () {
      const hint = 'Swipe left to bring the controls back';

      setUp(resetSharedPreferencesForTest);

      testWidgets('shows the first time only, on this device', (tester) async {
        final settings = (await tester.runAsync(SettingsService.getInstance))!;
        await pump(tester);
        await swipeRight(tester);
        expect(find.text(hint), findsOneWidget);
        expect(settings.read(SettingsService.reelImmersiveHintSeen), isTrue);

        ScaffoldMessenger.of(tester.element(find.byType(ReelFeedView))).removeCurrentSnackBar();
        await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
        await tester.pumpAndSettle();
        await swipeRight(tester);
        expect(find.text(hint), findsNothing);
      });

      testWidgets('stays away once seen', (tester) async {
        final settings = (await tester.runAsync(SettingsService.getInstance))!;
        await tester.runAsync(() => settings.write(SettingsService.reelImmersiveHintSeen, true));
        await pump(tester);
        await swipeRight(tester);
        expect(find.text(hint), findsNothing);
      });
    });
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
  group('V2-29: Details first, Save shows saved', () {
    Finder button<T extends Widget>(String label) =>
        find.ancestor(of: find.text(label).first, matching: find.byWidgetPredicate((w) => w is T));

    testWidgets('Details is the filled control; Watch here is tonal', (tester) async {
      await pump(tester);
      final details = tester.widget<ButtonStyleButton>(button<ButtonStyleButton>('Details').first);
      final watch = tester.widget<ButtonStyleButton>(button<ButtonStyleButton>('Watch').first);
      expect(details, isA<FilledButton>());
      expect(watch, isA<FilledButton>());
      expect(find.byType(OutlinedButton), findsNothing);
      // Tonal and filled are both FilledButtons; their fills differ.
      Color fill(String label) => tester
          .widget<Material>(find.ancestor(of: find.text(label).first, matching: find.byType(Material)).first)
          .color!;
      final scheme = Theme.of(tester.element(find.text('Details').first)).colorScheme;
      expect(fill('Details'), scheme.primary);
      expect(fill('Watch'), scheme.secondaryContainer);
      // Details leads the row.
      expect(tester.getCenter(find.text('Details').first).dx, lessThan(tester.getCenter(find.text('Watch').first).dx));
    });

    testWidgets('Watch on TV stays filled while connected', (tester) async {
      await pump(tester, watchOnTv: true);
      final scheme = Theme.of(tester.element(find.text('Details').first)).colorScheme;
      final fill = tester
          .widget<Material>(find.ancestor(of: find.text('Watch on TV').first, matching: find.byType(Material)).first)
          .color!;
      expect(fill, scheme.primary);
    });

    testWidgets('tapping the title block opens Details', (tester) async {
      await pump(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Like the films you finish.').first);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(opened.single.id, '1');
      await tester.runAsync(() async {
        await tester.tap(find.text('Title 1'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(opened.map((i) => i.id), ['1', '1']);
      expect(players.paused, isFalse, reason: 'the title is not the picture: it never pauses the clip');
    });

    Future<int> saves() async =>
        (await store.events(since: DateTime.utc(2000))).where((e) => e.action == ReelAction.save.name).length;

    testWidgets('Save fills the bookmark, bursts once and floats no toast', (tester) async {
      await pump(tester);
      expect(find.byTooltip('Save'), findsOneWidget);
      await tester.tap(find.byTooltip('Save'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(c.isSaved('t1'), isTrue);
      expect(find.byTooltip('Saved'), findsOneWidget);
      final icon = tester.widget<IconButton>(
        find.ancestor(of: find.byTooltip('Saved'), matching: find.byType(IconButton)),
      );
      expect(icon.isSelected, isTrue);
      expect(c.toast.value, isNull, reason: 'the feed saves silently');
      expect(await tester.runAsync(saves), 1);

      // A double-tap on the saved card neither bursts nor saves again.
      await tester.pump(const Duration(seconds: 1));
      final burst = find.byWidgetPredicate((w) => w is AnimatedOpacity && w.opacity == 1 && w.child is Center);
      expect(burst, findsNothing);
      final picture = tester.getCenter(find.byType(PageView)) - const Offset(0, 200);
      await tester.tapAt(picture);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(picture);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      expect(burst, findsNothing);
      expect(await tester.runAsync(saves), 1);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a double-tap on an unsaved card bursts and saves it', (tester) async {
      await pump(tester);
      final burst = find.byWidgetPredicate((w) => w is AnimatedOpacity && w.opacity == 1 && w.child is Center);
      final picture = tester.getCenter(find.byType(PageView)) - const Offset(0, 200);
      await tester.tapAt(picture);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(picture);
      await tester.pump(const Duration(milliseconds: 400));
      expect(burst, findsOneWidget);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(c.isSaved('t1'), isTrue);
      expect(await tester.runAsync(saves), 1);
      await tester.pump(const Duration(seconds: 1));
      expect(burst, findsNothing, reason: 'it fades away');
    });
  });

  group('V2-24: the feed is always dark', () {
    Color painted(WidgetTester tester, String text) => tester
        .widget<RichText>(find.descendant(of: find.text(text).first, matching: find.byType(RichText)))
        .text
        .style!
        .color!;

    // The feed's canvas and gradients are fixed black.
    const black = Color(0xFF000000);

    testWidgets('under Light the title, deck button and Details read on black', (tester) async {
      await pump(tester, appTheme: monoTheme(MonoPalette.light), palette: MonoPalette.light, themed: true);
      expect(Theme.of(tester.element(find.text('Title 1'))).brightness, Brightness.dark);
      for (final text in ['Title 1', 'Deck a']) {
        final ratio = MonoPalette.contrastRatio(Color.alphaBlend(painted(tester, text), black), black);
        expect(ratio, greaterThanOrEqualTo(PaletteContrastCheck.textOnBg.minimum), reason: '$text on black');
      }
      // Details is the filled button (V2-29): its fill must stand off the
      // black page and its label must read on that fill.
      final fill = tester
          .widget<Material>(find.ancestor(of: find.text('Details').first, matching: find.byType(Material)).first)
          .color!;
      expect(MonoPalette.contrastRatio(fill, black), greaterThanOrEqualTo(PaletteContrastCheck.accentOnBg.minimum));
      expect(
        MonoPalette.contrastRatio(painted(tester, 'Details'), fill),
        greaterThanOrEqualTo(PaletteContrastCheck.labelOnAccent.minimum),
      );
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
      );
      expect(region.value, SystemUiOverlayStyle.light);
    });

    testWidgets('without it a light app theme paints near-black text on black', (tester) async {
      // Guards the test above: the same feed, unthemed, fails the check.
      await pump(tester, appTheme: monoTheme(MonoPalette.light));
      final ratio = MonoPalette.contrastRatio(Color.alphaBlend(painted(tester, 'Title 1'), black), black);
      expect(ratio, lessThan(PaletteContrastCheck.textOnBg.minimum));
    });

    testWidgets('a light palette falls back to Dark; a dark one is kept', (tester) async {
      Future<ThemeData> themeUnder(MonoPalette palette) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: monoTheme(MonoPalette.light),
            home: ReelFeedTheme(palette: palette, child: const ReelCurtain()),
          ),
        );
        return Theme.of(tester.element(find.byType(CircularProgressIndicator)));
      }

      // Theme.of localises the data, so compare the palette the theme carries.
      Color bg(ThemeData theme) => theme.extension<MonoTokens>()!.bg;

      const dark = MonoPalette.forest;
      expect(dark.brightness, Brightness.dark);
      expect(MonoPalette.paper.brightness, Brightness.light);
      expect(bg(await themeUnder(MonoPalette.paper)), MonoPalette.dark.bg);
      expect(bg(await themeUnder(dark)), dark.bg);
    });

    testWidgets('the loading curtain is dark, not the light app page', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(MonoPalette.light),
          home: const ReelFeedTheme(palette: MonoPalette.light, child: ReelCurtain()),
        ),
      );
      final box = tester.widget<ColoredBox>(
        find.ancestor(of: find.byType(CircularProgressIndicator), matching: find.byType(ColoredBox)).first,
      );
      expect(box.color.computeLuminance(), lessThan(0.1));
    });
  });
}
