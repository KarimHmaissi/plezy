import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/memory_trim_policy.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/feed_players.dart';
import 'package:plezy/services/reel/reel_art.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_data_budget.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_motion.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/theme/mono_tokens.dart';
import 'package:plezy/theme/palette_contrast.dart';
import 'package:plezy/utils/immersive_mode_guard.dart';
import 'package:plezy/utils/media_image_helper.dart';
import 'package:plezy/widgets/cycling_media_backdrop.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/pressable.dart';
import 'package:plezy/widgets/tv_spotlight_background.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/reel_link.dart';
import 'clip_player_test.dart' show FakeClipEngine;

class _Servers implements ReelServers {
  _Servers([Set<String>? bare]) : bare = bare ?? {};

  /// Titles with no extras: they end as AI cards.
  final Set<String> bare;

  /// When set, the clip lookups wait for it (V2-26: a clip found late).
  Completer<void>? gate;

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    await gate?.future;
    return [
      if (!bare.contains(ratingKey))
        PlexExtraClip(
          ratingKey: 'x$ratingKey',
          title: 'Trailer',
          partKey: '/iva/$ratingKey.mp4',
          subtype: 'trailer',
          index: 0,
        ),
    ];
  }

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

  /// The server can't be reached (V2-27).
  bool fails = false;

  @override
  Future<List<ReelCardData>> load() async {
    if (fails) throw StateError('server unreachable');
    return [for (final i in ids) special[i] ?? _card(i)];
  }
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
  Duration at = Duration.zero;
  int seeks = 0;

  /// The clip's own shape.
  double ratio = 16 / 9;

  /// When set, the open waits for it: no first frame until it completes.
  Completer<void>? opening;

  /// The clip broke mid-play.
  bool broken = false;
  @override
  bool get ready => _ready;
  @override
  bool get failed => broken;
  @override
  double get aspectRatio => ratio;
  @override
  Duration get position => at;
  @override
  Duration get duration => const Duration(seconds: 60);
  @override
  bool get playing => _playing;
  @override
  bool get buffering => false;
  @override
  Duration get buffered => _ready ? duration : Duration.zero;
  @override
  Future<void> initialize() async {
    await opening?.future;
    _ready = true;
  }

  /// The clip breaks mid-play.
  void breakDown() {
    broken = true;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    // As the plugin does: a play from the end starts at the top.
    if (completed) at = Duration.zero;
    completed = false;
    _playing = true;
  }

  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> seekTo(Duration position) async {
    seeks++;
    at = position;
    completed = position == duration;
  }

  /// The plugin's position poll.
  void tick(Duration to) {
    at = to;
    notifyListeners();
  }

  @override
  bool completed = false;
  bool? looping;
  @override
  Future<void> setLooping(bool on) async => looping = on;

  /// The clip reaches its end with looping off: the plugin pauses on the
  /// last frame.
  void end() {
    _playing = false;
    at = duration;
    completed = true;
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

  /// Clip shapes by card, for clips that aren't 16:9.
  late Map<String, double> ratios;

  /// When set, every clip's open waits for it (V2-67: before the first frame).
  Completer<void>? opening;
  late ReelStore store;
  late List<MediaItem> opened;
  late int decksOpened, watched, sheets, resized;
  late List<bool> immersiveReports;
  late ValueNotifier<int> restored;
  late ValueNotifier<int> link, settingsChanged;
  late bool onCellular;
  late ReelCellular cellular;
  late _Deck first;
  late _Servers servers;
  late _Media media;

  /// The clip-end pref (V2-47), how far the clock has run on, and the
  /// cards with no trailer.
  late ReelClipEnd clipEnd;
  late Duration skew;
  late Set<String> noClip;

  setUp(() {
    ReelArt.resetForTesting();
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    opened = [];
    decksOpened = watched = sheets = resized = 0;
    immersiveReports = [];
    restored = ValueNotifier(0);
    clipEnd = ReelClipEnd.twiceThenHold;
    skew = Duration.zero;
    noClip = {};
    link = ValueNotifier(0);
    settingsChanged = ValueNotifier(0);
    onCellular = false;
    cellular = ReelCellular.dataSaver;
    c = ReelController(
      decks: [
        first = _Deck('a', ['1', '2', '3', '4']),
        _Deck('b', ['9']),
      ],
      resolver: ClipResolver(
        servers: servers = _Servers(noClip),
        store: store,
        aniList: (_) async => null,
        animeThemes: (_) async => const {},
        profile: FakeLinkProfile(() => onCellular, link),
      ),
      clips: ClipPlayer(engine: FakeClipEngine.new),
      store: store,
      media: media = _Media(),
      onWatch: (_, {required onTv}) async => true,
      addToWatchlist: (_) async => true,
      externalClips: true,
      memoryRestored: restored,
      settingsChanged: settingsChanged,
      cellular: () => cellular,
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
      clipEnd: () => clipEnd,
      clock: () => DateTime.now().add(skew),
    );
    // No stuck-card watchdog here either (a timer left behind); its own
    // tests arm it.
    c.stuckAfter = null;
    videos = {};
    ratios = {};
    opening = null;
    players = ReelFeedPlayers(
      create: (uri) {
        final id = uri.pathSegments.last.split('.').first;
        return videos[id] = _Video()
          ..ratio = ratios[id] ?? 16 / 9
          ..opening = opening;
      },
      // Full volume at once: the rise (V2-19) is covered in
      // feed_players_test.dart and would leave a timer behind here.
      riseOver: Duration.zero,
      // No stuck-card watchdog (it would leave a timer behind too): the
      // tests that time it out make their own players.
      stuckAfter: null,
      plays: () => clipEnd.plays,
    );
  });

  tearDown(() async {
    c.dispose();
    players.dispose();
    restored.dispose();
    link.dispose();
    settingsChanged.dispose();
    await db.close();
  });

  Widget feed({bool watchOnTv = false}) => ReelFeedView(
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
    bool screenReader = false,
    Widget Function(Widget feed)? wrap,
    Size size = const Size(420, 860),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(c.start);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme ?? ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(accessibleNavigation: screenReader),
          child: child!,
        ),
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

    // Mobile data on the default Data saver (V2-53): the link change reaches
    // the feed through the controller.
    onCellular = true;
    link.value++;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(players.current, 't2');
    expect(players.held.toSet(), {'t2', 't3'}, reason: 'the card on screen and the next only');

    onCellular = false;
    link.value++;
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

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('on Wi-Fi the next two and the one behind are parked', (tester) async {
    await pump(tester);
    expect(players.held.toSet(), {'t1', 't2', 't3'});
    await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(players.held.toSet(), {'t2', 't3', 't4', 't1'});
  });

  testWidgets('Data saver on mobile data keeps the card on screen and the next one only', (tester) async {
    onCellular = true;
    await pump(tester);
    expect(c.dataBudget, ReelDataBudget.saver);
    expect(players.held.toSet(), {'t1', 't2'});
    expect(players.current, 't1');

    await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(players.current, 't2');
    expect(players.held.toSet(), {'t2', 't3'}, reason: 'the card behind lets its player go');
  });

  testWidgets('Stills only on mobile data opens no player; back on Wi-Fi the clips come back', (tester) async {
    onCellular = true;
    cellular = ReelCellular.stillsOnly;
    await pump(tester);
    expect(players.held, isEmpty);
    expect(find.text('Title 1'), findsOneWidget, reason: 'the card shows its art and title');

    onCellular = false;
    link.value++;
    await settle(tester);
    expect(players.held.toSet(), {'t1', 't2', 't3'});
    expect(players.current, 't1');
  });

  testWidgets('a mobile-data choice made while the Reel plays is taken up at once', (tester) async {
    onCellular = true;
    cellular = ReelCellular.normal;
    await pump(tester);
    expect(players.held.toSet(), {'t1', 't2', 't3'}, reason: 'Normal plays as on Wi-Fi');

    cellular = ReelCellular.stillsOnly;
    settingsChanged.value++;
    await settle(tester);
    expect(players.held, isEmpty);

    cellular = ReelCellular.dataSaver;
    settingsChanged.value++;
    await settle(tester);
    expect(players.held.toSet(), {'t1', 't2'});
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

  testWidgets('the still decodes at the frame it is shown in, not a fixed 960 px', (tester) async {
    await pump(tester);
    final page = tester.getSize(find.byType(ReelFeedView));
    final stills = [
      for (final a in tester.widgetList<OptimizedMediaImage>(find.byType(OptimizedMediaImage)))
        if (a.width != 36) a,
    ];
    expect(stills, isNotEmpty);
    for (final still in stills) {
      // The card's 16:9 frame, where 960 x DPR hit the 1920x1080 cap; set
      // rather than read from the frame, so a glide never decodes it again.
      final size = tester.getSize(find.byWidget(still));
      expect(size.width, lessThanOrEqualTo(420));
      expect(size.height, moreOrLessEquals(size.width * 9 / 16, epsilon: 1));
      expect(Size(still.width!, still.height!), size);
      expect(still.imageType, ImageType.art);
      // The size the next cards' art is warmed at (V2-13).
      expect(size, reelStillDecode(page, ReelFeedLayout.of(page), 16 / 9));
    }
  });

  testWidgets("the feed's art is tracked as its card's, for the Reel's art budget", (tester) async {
    await pump(tester);
    final art = [
      for (final a in tester.widgetList<OptimizedMediaImage>(find.byType(OptimizedMediaImage)))
        if (a.onImageProvider != null) a,
    ];
    // The ambient backdrop and the still of the card on screen and the one
    // built ahead.
    expect(art.length, greaterThanOrEqualTo(2));
    final provider = _PendingArt('harbor-lights-art');
    art.first.onImageProvider!(provider);
    expect(ReelArt.cardOf(provider), 't1');
  });

  test("a still's decode: its frame in the picture's area, all the page in immersive two panes", () {
    const phone = Size(400, 800);
    expect(reelStillDecode(phone, ReelFeedLayout.phone, 16 / 9), const Size(400, 225));
    // A clip's own shape, once known; wider than 16:9 stays page-wide.
    expect(reelStillDecode(phone, ReelFeedLayout.phone, 2.0), const Size(400, 200));
    const inner = Size(1000, 700);
    final pane = reelStillDecode(inner, ReelFeedLayout.twoPane, 16 / 9);
    expect(pane.width, moreOrLessEquals(1000 * ReelFeedLayout.pictureShare));
    expect(reelStillDecode(inner, ReelFeedLayout.twoPane, 16 / 9, immersive: true), const Size(1000, 562.5));
  });

  testWidgets('the feed warms the next cards\' art while it is mounted (V2-13)', (tester) async {
    await pump(tester);
    expect(c.artPrecache, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(c.artPrecache, isNull, reason: 'a feed that has gone builds no art');
  });

  group('V2-67: black behind a playing clip', () {
    /// The card's art behind the picture (the ambient backdrop) and under
    /// it (the still), as their fades stand.
    AnimatedOpacity fadeOf(WidgetTester tester, String slot, String id) => tester.widget<AnimatedOpacity>(
      find.descendant(of: find.byKey(ValueKey((slot, id))), matching: find.byType(AnimatedOpacity)).first,
    );
    double ambient(WidgetTester tester, String id) => fadeOf(tester, 'reel-ambient-art', id).opacity;
    double still(WidgetTester tester, String id) => fadeOf(tester, 'reel-still-art', id).opacity;

    /// [id]'s own clip picture in its frame.
    double clip(WidgetTester tester, String id) {
      final frame = find.ancestor(of: find.byKey(ValueKey(('reel-still-art', id))), matching: find.byType(Stack)).first;
      final picture = find.descendant(
        of: frame,
        matching: find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.teal),
      );
      return tester
          .widget<AnimatedOpacity>(find.ancestor(of: picture, matching: find.byType(AnimatedOpacity)).first)
          .opacity;
    }

    Future<void> firstFrame(WidgetTester tester) async {
      await tester.runAsync(() async {
        opening!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('the art shows until the first frame, then fades out and the clip plays on black', (tester) async {
      opening = Completer<void>();
      await pump(tester);
      expect(players.videoFor('t1'), isNull, reason: 'no first frame yet');
      expect(ambient(tester, 't1'), 1);
      expect(still(tester, 't1'), 1);

      await firstFrame(tester);
      expect(players.videoFor('t1'), isNotNull);
      expect(ambient(tester, 't1'), 0);
      expect(still(tester, 't1'), 0);
      expect(clip(tester, 't1'), 1);
      // What is left behind the picture is the feed's own black ground.
      expect(
        tester
            .widget<ColoredBox>(find.ancestor(of: find.byType(PageView), matching: find.byType(ColoredBox)).first)
            .color,
        Colors.black,
      );
    });

    testWidgets('the art fades on the slow token, not at a cut', (tester) async {
      opening = Completer<void>();
      await pump(tester, themed: true, palette: MonoPalette.dark);
      await tester.runAsync(() async {
        opening!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      final fade = fadeOf(tester, 'reel-ambient-art', 't1');
      final slow = Theme.of(tester.element(find.byType(PageView))).extension<MonoTokens>()!.slow;
      expect(fade.opacity, 0);
      expect(fade.duration, slow);
      expect(fade.curve, MonoMotion.standard);
      await tester.pumpAndSettle();
    });

    testWidgets('a pause or a held last frame keeps it black', (tester) async {
      await pump(tester);
      expect(ambient(tester, 't1'), 0);

      await tester.runAsync(players.togglePause);
      await tester.pumpAndSettle();
      expect(players.paused, isTrue);
      expect(ambient(tester, 't1'), 0);
      expect(still(tester, 't1'), 0);
      await tester.runAsync(players.togglePause);
      await tester.pumpAndSettle();

      // Twice then hold: the last play stops on its final frame (V2-47).
      final v = videos['1']!
        ..tick(const Duration(seconds: 5))
        ..tick(const Duration(seconds: 55))
        ..tick(const Duration(milliseconds: 200))
        ..tick(const Duration(seconds: 5))
        ..end();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(v.completed, isTrue);
      expect(players.card('t1').value.held, isTrue, reason: 'held for Replay');
      expect(ambient(tester, 't1'), 0);
      expect(still(tester, 't1'), 0);
    });

    testWidgets('a clip that breaks gives the art back', (tester) async {
      await pump(tester);
      expect(ambient(tester, 't1'), 0);
      videos['1']!.breakDown();
      await tester.pumpAndSettle();
      expect(ambient(tester, 't1'), 1);
      expect(still(tester, 't1'), 1);
      expect(players.videoFor('t1'), isNull, reason: 'the broken player is let go');
      expect(
        find.descendant(
          of: find
              .ancestor(of: find.byKey(const ValueKey(('reel-still-art', 't1'))), matching: find.byType(Stack))
              .first,
          matching: find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.teal),
        ),
        findsNothing,
        reason: 'the broken picture no longer covers the still',
      );
    });

    testWidgets('an AI card keeps its art', (tester) async {
      servers.bare.add('1');
      await pump(tester);
      expect(c.current.isAiCard, isTrue);
      await tester.pumpAndSettle();
      expect(players.videoFor('t1'), isNull);
      expect(ambient(tester, 't1'), 1);
      expect(still(tester, 't1'), 1);
    });

    testWidgets('a position report alone does not rebuild the art', (tester) async {
      await pump(tester);
      final before = tester.widget(find.byKey(const ValueKey(('reel-ambient-art', 't1'))));
      videos['1']!.tick(const Duration(seconds: 3));
      await tester.pump();
      expect(identical(tester.widget(find.byKey(const ValueKey(('reel-ambient-art', 't1')))), before), isTrue);
    });
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
      // The backdrop and logo it builds count as this card's in the Reel's
      // art budget, and suspend lets them go.
      final art = _PendingArt('harbor-lights-thumb');
      spotlight(tester).onArtProvider!(art);
      expect(ReelArt.cardOf(art), c.current.card!.id);
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

    testWidgets('a card whose clip never starts falls back to its art and premise (stuck card)', (tester) async {
      // The players as the Reel screen wires them: a failed clip is told to
      // the controller, and the card on screen is timed out.
      players.dispose();
      final failures = <String>[];
      players = ReelFeedPlayers(
        create: (uri) {
          final id = uri.pathSegments.last.split('.').first;
          // Card 1's clip opens and never moves.
          return videos[id] = _Video()..opening = opening;
        },
        riseOver: Duration.zero,
        onFailed: (id) {
          failures.add(id);
          unawaited(c.clipFailed(id));
        },
      );
      await pump(tester);
      expect(c.current.clip, isNotNull);
      expect(players.videoFor('t1'), isNotNull);
      expect(find.text(premise), findsNothing);

      await tester.pump(FeedWatchdog.after - const Duration(milliseconds: 500));
      expect(failures, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(failures, ['t1']);
      // Looked up once more without the failed trailer: the card has no other.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(c.current.isAiCard, isTrue);
      expect(players.videoFor('t1'), isNull, reason: 'no frozen picture is left on the page');
      expect(find.text(premise), findsOneWidget);
      // No timer left behind for the tree's teardown.
      await tester.runAsync(players.releaseAll);
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

  testWidgets('a deck that fails to load says so, and Try again loads it (V2-27)', (tester) async {
    first.fails = true;
    await pump(tester);
    expect(c.current.kind, ReelSlotKind.failed);
    expect(find.text("Couldn't load Deck a"), findsOneWidget);
    expect(find.textContaining('Nothing in'), findsNothing);

    first.fails = false;
    await tester.runAsync(() async {
      await tester.tap(find.text('Try again'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('Title 1'), findsOneWidget);
  });

  group('metadata landing late (V2-26)', () {
    /// The feed with every item held back until the gate opens; with
    /// [clipLate], the clip lookups too (the clip no longer waits on the
    /// metadata, V2-03, so each can land on its own).
    Future<void> pumpGated(WidgetTester tester, {bool reduceMotion = false, bool clipLate = false}) async {
      media.gate = Completer<void>();
      if (clipLate) servers.gate = Completer<void>();
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
      servers.gate?.complete();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(c.current.item, isNotNull);
      await tester.pump();
    }

    Finder line() => find.byType(ReelMetadataLine).first;
    Finder block() => find.ancestor(of: find.text('Title 1'), matching: find.byType(AnimatedSize)).first;

    testWidgets('the title stays put: the facts line keeps its height when the metadata lands', (tester) async {
      await pumpGated(tester);
      final lineHeight = tester.getSize(line()).height;
      expect(lineHeight, greaterThan(0), reason: 'the line is reserved before anything is known');
      expect(find.text('PG'), findsNothing);
      final title = tester.getRect(find.text('Title 1'));
      final blockTop = tester.getRect(block()).top;

      await land(tester);
      expect(find.text('PG'), findsOneWidget);
      expect(tester.getRect(find.text('Title 1')).topLeft, title.topLeft);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('Title 1')).topLeft, title.topLeft);
      expect(tester.getRect(block()).top, closeTo(blockTop, 0.5), reason: 'nothing above the title changed');
      expect(tester.getSize(line()).height, closeTo(lineHeight, 0.5));
    });

    testWidgets('a clip found late grows the block by gliding, and the title stays put', (tester) async {
      await pumpGated(tester, clipLate: true);
      final title = tester.getRect(find.text('Title 1'));
      final blockTop = tester.getRect(block()).top;

      final grow = tester.widget<AnimatedSize>(block());
      expect(grow.alignment, Alignment.bottomLeft);
      expect(grow.duration, const Duration(milliseconds: 200));
      expect(grow.curve, MonoMotion.standard);

      await land(tester);
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
    });

    testWidgets('with animations off the block changes at once', (tester) async {
      await pumpGated(tester, reduceMotion: true, clipLate: true);
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
  group('mute (V2-22)', () {
    setUp(resetSharedPreferencesForTest);

    testWidgets('the button goes through the controller: the unmute is recorded and kept', (tester) async {
      final settings = (await tester.runAsync(SettingsService.getInstance))!;
      await pump(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Mute'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(players.muted, isTrue);
      expect(c.muted, isTrue);
      expect(settings.read(SettingsService.reelMuted), isTrue);

      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Sound on'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(players.muted, isFalse);
      expect(settings.read(SettingsService.reelMuted), isFalse);
      final events = (await tester.runAsync(() => store.events(since: DateTime(2000))))!;
      expect(events.map((e) => e.action), contains(ReelAction.unmute.name));
    });
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

  group('V2-32: reduced motion goes through the app gates', () {
    tearDown(DevicePerformance.debugReset);

    void reduceMotion(WidgetTester tester) {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
        disableAnimations: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    }

    /// The feed's own motions: the info and the picture's fades, the
    /// picture gliding to centre, the art dimming, and the top bar.
    List<Duration> motions(WidgetTester tester) {
      final page = find.byType(PageView);
      // Pressable's press wash is the app's own, gated where it starts.
      final pressable = tester
          .widgetList(find.descendant(of: find.byType(Pressable), matching: find.byType(AnimatedOpacity)))
          .toSet();
      Iterable<Duration> under<T extends ImplicitlyAnimatedWidget>(Finder of) => tester
          .widgetList<T>(find.descendant(of: of, matching: find.byType(T)))
          .where((w) => !pressable.contains(w))
          .map((w) => w.duration);
      return [
        ...under<AnimatedOpacity>(page),
        ...under<AnimatedAlign>(page),
        ...under<AnimatedContainer>(page),
        tester
            .widget<AnimatedOpacity>(find.ancestor(of: find.text('Deck a'), matching: find.byType(AnimatedOpacity)))
            .duration,
      ];
    }

    final burst = find.ancestor(
      of: find.byWidgetPredicate((w) => w is Icon && w.size == 96),
      matching: find.byType(AnimatedOpacity),
    );
    Duration burstGrow(WidgetTester tester) => tester
        .widget<TweenAnimationBuilder<double>>(
          find.descendant(of: burst, matching: find.byType(TweenAnimationBuilder<double>)),
        )
        .duration;

    testWidgets('at full motion every one of them runs', (tester) async {
      await pump(tester);
      final all = motions(tester);
      expect(all.length, greaterThanOrEqualTo(6));
      expect(all, everyElement(greaterThan(Duration.zero)));
      expect(burstGrow(tester), greaterThan(Duration.zero));
    });

    testWidgets('with reduce motion on they all happen at once; the Save burst only fades', (tester) async {
      reduceMotion(tester);
      await pump(tester);
      expect(motions(tester), everyElement(Duration.zero));
      expect(burstGrow(tester), Duration.zero);
      expect(tester.widget<AnimatedOpacity>(burst).duration, greaterThan(Duration.zero));

      // Swiping right hides the controls on the next frame, with no fade.
      await tester.fling(find.text('Title 1'), const Offset(300, 0), 1500);
      await tester.pump();
      await tester.pump();
      final info = tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.text('Details'), matching: find.byType(AnimatedOpacity)).first,
      );
      expect(info.opacity, 0);
      expect(
        tester
            .widget<FadeTransition>(
              find.ancestor(of: find.text('Details'), matching: find.byType(FadeTransition)).first,
            )
            .opacity
            .value,
        0,
      );
      await tester.pumpAndSettle();
    });

    testWidgets('on the reduced effects tier they all happen at once, the burst too', (tester) async {
      DevicePerformance.debugReset(autoReduced: true);
      await pump(tester);
      expect(motions(tester), everyElement(Duration.zero));
      expect(burstGrow(tester), Duration.zero);
      expect(tester.widget<AnimatedOpacity>(burst).duration, Duration.zero);
    });

    testWidgets('on the reduced effects tier the hairline steps with the reports', (tester) async {
      DevicePerformance.debugReset(autoReduced: true);
      await pump(tester);
      videos['1']!.tick(const Duration(seconds: 30));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.5, 0.0001));
    });

    testWidgets('the deck strip shows and goes at once with reduce motion on', (tester) async {
      Duration strip() => tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration;
      Widget host() => MaterialApp(
        home: Stack(children: [ReelDeckStrip(controller: c)]),
      );
      await tester.pumpWidget(host());
      expect(strip(), greaterThan(Duration.zero));
      reduceMotion(tester);
      await tester.pumpWidget(host());
      expect(strip(), Duration.zero);
    });
  });

  group('V2-30: layouts for the Fold, and the frame glides', () {
    // The cover screen upright and on its side; the inner screen upright and
    // on its side.
    const cover = Size(420, 860);
    const coverSideways = Size(860, 400);
    const innerUpright = Size(700, 860);
    const innerSideways = Size(880, 700);

    tearDown(ImmersiveModeGuard.resetForTesting);

    Future<void> resize(WidgetTester tester, Size to) async {
      tester.view.physicalSize = to;
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }

    /// The clip's picture on screen (the fake player draws teal).
    final video = find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.teal);

    bool scrimOver(WidgetTester tester, Finder of) => tester
        .widgetList<DecoratedBox>(find.ancestor(of: of, matching: find.byType(DecoratedBox)))
        .any((w) => w.decoration is BoxDecoration && (w.decoration as BoxDecoration).gradient != null);

    test('the layout follows the space: the app\'s 600 dp line and the two-pane rule', () {
      expect(ReelFeedLayout.of(cover), ReelFeedLayout.phone);
      expect(ReelFeedLayout.of(coverSideways), ReelFeedLayout.fullBleed);
      expect(ReelFeedLayout.of(innerUpright), ReelFeedLayout.stacked);
      expect(ReelFeedLayout.of(innerSideways), ReelFeedLayout.twoPane);
      // On its side but under 800 wide: the info stays below the picture.
      expect(ReelFeedLayout.of(const Size(780, 650)), ReelFeedLayout.stacked);
      // 800 wide and taller than wide is not two-pane.
      expect(ReelFeedLayout.of(const Size(820, 1000)), ReelFeedLayout.stacked);
      expect(ReelFeedLayout.of(const Size(599, 900)), ReelFeedLayout.phone);
    });

    testWidgets('phone: as before, the info over the foot of the picture, at the phone inset', (tester) async {
      await pump(tester);
      expect(scrimOver(tester, find.text('Details')), isTrue);
      expect(tester.getTopLeft(find.text('Title 1')).dx, 20, reason: 'ForkSpacing.phone.edgeInset');
      expect(find.text('Up next'), findsNothing);
    });

    testWidgets('inner screen upright: the picture at the top and the info below it, nothing over the picture', (
      tester,
    ) async {
      await pump(tester, size: innerUpright);
      final picture = tester.getRect(video);
      expect(picture.top, greaterThanOrEqualTo(56), reason: 'below the top bar');
      expect(tester.getTopLeft(find.text('Title 1')).dy, greaterThanOrEqualTo(picture.bottom));
      expect(tester.getTopLeft(find.text('Details')).dy, greaterThanOrEqualTo(picture.bottom));
      expect(scrimOver(tester, find.text('Details')), isFalse);
      expect(tester.getTopLeft(find.text('Title 1')).dx, 28, reason: 'ForkSpacing.tablet.edgeInset');
      expect(find.text('Up next'), findsNothing);
    });

    testWidgets('inner screen on its side: picture 62, info 38 with Up next, and no scrim over the video', (
      tester,
    ) async {
      await pump(tester, size: innerSideways);
      final split = innerSideways.width * ReelFeedLayout.pictureShare;
      expect(tester.getRect(video).right, lessThanOrEqualTo(split + 0.5));
      expect(tester.getTopLeft(find.text('Details')).dx, greaterThanOrEqualTo(split));
      expect(tester.getTopLeft(find.text('Title 1')).dx, closeTo(split + 28, 0.5));
      expect(scrimOver(tester, find.text('Details')), isFalse);
      expect(find.text('Up next'), findsOneWidget);
      for (final t in ['Title 2', 'Title 3', 'Title 4']) {
        expect(find.text(t), findsOneWidget, reason: '$t is up next');
      }
      expect(tester.takeException(), isNull, reason: 'nothing overflows the pane');
    });

    testWidgets('an Up next row takes the feed to that card, committed on the settle', (tester) async {
      await pump(tester, size: innerSideways);
      await tester.tap(find.text('Title 2'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(c.index, 1);
      expect(players.current, 't2');
      expect(find.text('Title 3'), findsOneWidget);

      // Two ahead: a jump, so the card between opens nothing on the way.
      await tester.tap(find.text('Title 4'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(c.index, 3);
      expect(players.current, 't4');
    });

    testWidgets('immersive on the inner screen folds the info away and the picture takes the page', (tester) async {
      await pump(tester, size: innerSideways);
      final before = tester.getRect(video);
      await tester.fling(find.text('Title 1'), const Offset(300, 0), 1500);
      await tester.pumpAndSettle();
      expect(hidden(tester, 'Details'), isTrue);
      expect(tester.getRect(video).width, greaterThan(before.width));
      expect(tester.getRect(video).center.dx, closeTo(innerSideways.width / 2, 0.5));
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
      await tester.pumpAndSettle();
      expect(tester.getRect(video), before);
    });

    testWidgets('the cover screen on its side goes full-bleed by itself, and upright again comes back out', (
      tester,
    ) async {
      await pump(tester);
      await resize(tester, coverSideways);
      expect(hidden(tester, 'Details'), isTrue);
      expect(hidden(tester, 'Deck a'), isTrue);
      expect(immersiveReports, [true]);
      expect(tester.getRect(video).height, closeTo(coverSideways.height, 0.5), reason: 'the picture fills the height');

      await resize(tester, cover);
      expect(hidden(tester, 'Details'), isFalse);
      expect(immersiveReports, [true, false]);
    });

    testWidgets('on its side, controls asked back stay until the next turn', (tester) async {
      await pump(tester, size: coverSideways);
      await tester.pumpAndSettle();
      expect(hidden(tester, 'Details'), isTrue, reason: 'opened on its side');
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
      await tester.pumpAndSettle();
      expect(hidden(tester, 'Details'), isFalse);

      await resize(tester, const Size(860, 390));
      expect(hidden(tester, 'Details'), isFalse, reason: 'a size change on its side leaves the controls');
      await resize(tester, cover);
      expect(hidden(tester, 'Details'), isFalse);
      await resize(tester, coverSideways);
      expect(hidden(tester, 'Details'), isTrue, reason: 'a new turn goes full-bleed again');
    });

    testWidgets('immersive chosen upright stays when turned and turned back', (tester) async {
      await pump(tester);
      await tester.fling(find.text('Title 1'), const Offset(300, 0), 1500);
      await tester.pumpAndSettle();
      await resize(tester, coverSideways);
      await resize(tester, cover);
      expect(hidden(tester, 'Details'), isTrue);
      expect(immersiveReports, [true]);
    });

    testWidgets('the frame glides from 16:9 to the clip\'s own shape', (tester) async {
      ratios['1'] = 4 / 3;
      await pump(tester);
      double shape() =>
          tester.widget<AspectRatio>(find.ancestor(of: video, matching: find.byType(AspectRatio)).first).aspectRatio;
      expect(shape(), closeTo(16 / 9, 0.001), reason: 'the glide has only begun');
      await tester.pump(const Duration(milliseconds: 100));
      expect(shape(), allOf(lessThan(16 / 9), greaterThan(4 / 3)));
      await tester.pumpAndSettle();
      expect(shape(), closeTo(4 / 3, 0.001));
    });

    testWidgets('with reduce motion on the frame takes the clip\'s shape at once', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
        disableAnimations: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      ratios['1'] = 4 / 3;
      await pump(tester);
      await tester.pump();
      expect(
        tester.widget<AspectRatio>(find.ancestor(of: video, matching: find.byType(AspectRatio)).first).aspectRatio,
        closeTo(4 / 3, 0.001),
      );
    });

    testWidgets('the progress track is the theme\'s foreground, not white', (tester) async {
      await pump(tester, themed: true, palette: MonoPalette.oled);
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      final context = tester.element(find.byType(LinearProgressIndicator));
      expect(bar.backgroundColor, Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12));
    });
  });
  group('when a clip ends (V2-47)', () {
    Finder replay() => find.widgetWithText(FilledButton, 'Replay');

    /// Some page shows Replay: its own fade is in and nothing above it
    /// ignores taps (the pages either side carry a hidden one).
    bool replayShown(WidgetTester tester) {
      for (final e in replay().evaluate()) {
        final b = find.byElementPredicate((x) => x == e);
        final fade = tester.widget<AnimatedOpacity>(find.ancestor(of: b, matching: find.byType(AnimatedOpacity)).first);
        final blocked = tester
            .widgetList<IgnorePointer>(find.ancestor(of: b, matching: find.byType(IgnorePointer)))
            .any((w) => w.ignoring);
        if (fade.opacity == 1 && !blocked) return true;
      }
      return false;
    }

    /// The card's clip plays a little, then reaches its end.
    Future<void> playOut(WidgetTester tester, String id) async {
      videos[id]!
        ..tick(const Duration(seconds: 5))
        ..end();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    testWidgets('twice then hold: the second play holds its last frame with Replay', (tester) async {
      await pump(tester);
      final v = videos['1']!;
      expect(v.looping, isTrue, reason: 'the first play loops into the second');
      expect(replayShown(tester), isFalse);
      v
        ..tick(const Duration(seconds: 5))
        ..tick(const Duration(seconds: 55))
        ..tick(const Duration(milliseconds: 200));
      await tester.pump();
      expect(v.looping, isFalse, reason: 'the last play stops on its final frame');
      await playOut(tester, '1');
      expect(players.current, 't1', reason: 'it holds rather than moving on');
      expect(v.playing, isFalse);
      expect(replayShown(tester), isTrue);

      await tester.tap(replay());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(v.playing, isTrue);
      expect(v.position, Duration.zero);
      expect(replayShown(tester), isFalse);
      final events = await tester.runAsync(() => store.events(since: DateTime(2000)));
      expect(events!.map((e) => e.action), contains(ReelAction.replay.name));
    });

    testWidgets('a tap on the held picture replays it too', (tester) async {
      clipEnd = ReelClipEnd.nextCard;
      // Long idle: next card holds instead of moving on.
      await pump(tester);
      skew = ReelController.leanBackIdle;
      await playOut(tester, '1');
      expect(players.current, 't1');
      expect(replayShown(tester), isTrue);
      await tester.tapAt(tester.getCenter(find.byType(PageView)) - const Offset(0, 140));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(videos['1']!.playing, isTrue);
      expect(replayShown(tester), isFalse);
    });

    testWidgets('next card slides on to the next card once the clip has played', (tester) async {
      clipEnd = ReelClipEnd.nextCard;
      await pump(tester);
      expect(videos['1']!.looping, isFalse, reason: 'one play, ending on its last frame');
      await playOut(tester, '1');
      expect(players.current, 't2');
      expect(c.index, 1, reason: 'the step commits on the settle');
      expect(videos['2']!.playing, isTrue);
    });

    testWidgets('next card passes over an AI card', (tester) async {
      clipEnd = ReelClipEnd.nextCard;
      noClip.add('2');
      await pump(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(c.slotAt(1).isAiCard, isTrue);
      await playOut(tester, '1');
      expect(players.current, 't3');
      expect(c.index, 2);
    });

    testWidgets('after 30 minutes with no touch it holds; a touch lets it move on again', (tester) async {
      clipEnd = ReelClipEnd.nextCard;
      await pump(tester);
      skew = ReelController.leanBackIdle;
      await playOut(tester, '1');
      expect(players.current, 't1');
      expect(replayShown(tester), isTrue);

      // Any touch is someone there; Replay plays it again.
      await tester.tap(replay());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(c.mayRollOn, isTrue);
      await playOut(tester, '1');
      expect(players.current, 't2');
    });
  });

  group('with a screen reader (V2-54)', () {
    /// The card's own node: the nearest one over its title that carries the
    /// custom actions (the title block is also a Details button, V2-29, so
    /// it has a node of its own inside the card's).
    SemanticsNode cardNode(WidgetTester tester) {
      SemanticsNode? node = tester.getSemantics(find.text('Title 1'));
      while (node != null && (node.getSemanticsData().customSemanticsActionIds?.isEmpty ?? true)) {
        node = node.parent;
      }
      return node ?? tester.getSemantics(find.text('Title 1'));
    }

    Map<String, int> customActions(SemanticsNode node) => {
      for (final id in node.getSemanticsData().customSemanticsActionIds ?? const <int>[])
        CustomSemanticsAction.getAction(id)!.label!: id,
    };

    void perform(SemanticsNode node, int id) => node.owner!.performAction(node.id, SemanticsAction.customAction, id);

    testWidgets('each card is one node with Save, More and Hide controls; the feed keeps its scroll', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      final node = cardNode(tester);
      expect(customActions(node).keys, containsAll(['Save', 'More', 'Hide controls']));
      final data = node.getSemanticsData();
      expect(data.hasAction(SemanticsAction.scrollLeft), isFalse, reason: 'the sideways swipe stays out of the tree');
      expect(data.hasAction(SemanticsAction.scrollRight), isFalse);
      // The feed's scroll actions live on an ancestor: the PageView's own
      // scrollable node, not the card.
      final ancestors = <SemanticsNode>[];
      for (var n = node.parent; n != null; n = n.parent) {
        ancestors.add(n);
      }
      expect(
        ancestors.any((n) => n.getSemanticsData().hasAction(SemanticsAction.scrollUp)),
        isTrue,
        reason: 'the next card is still a scroll away',
      );

      perform(node, customActions(node)['More']!);
      expect(sheets, 1);

      perform(node, customActions(node)['Hide controls']!);
      await tester.pumpAndSettle();
      expect(hidden(tester, 'Deck a'), isTrue);
      final shown = cardNode(tester);
      expect(customActions(shown).keys, contains('Show controls'));
      perform(shown, customActions(shown)['Show controls']!);
      await tester.pumpAndSettle();
      expect(hidden(tester, 'Deck a'), isFalse);
      semantics.dispose();
    });

    testWidgets('Save from the card node saves the card on screen', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      final node = cardNode(tester);
      await tester.runAsync(() async {
        perform(node, customActions(node)['Save']!);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      final picks = await tester.runAsync(c.store.picks);
      expect(picks?.map((p) => p.titleId), contains('t1'));
      semantics.dispose();
    });

    testWidgets('the Reel starts muted and the swipe no longer hides the controls', (tester) async {
      await pump(tester, screenReader: true);
      await settle(tester);
      expect(players.muted, isTrue);

      await tester.fling(find.text('Title 1'), const Offset(300, 0), 1500);
      await tester.pumpAndSettle();
      expect(hidden(tester, 'Details'), isFalse);
      expect(hidden(tester, 'Deck a'), isFalse);

      // Unmuting afterwards sticks.
      await tester.tap(find.byTooltip('Sound on'));
      await settle(tester);
      expect(players.muted, isFalse);
      await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(players.muted, isFalse);
    });

    testWidgets('without one, the Reel starts with sound', (tester) async {
      await pump(tester);
      await settle(tester);
      expect(players.muted, isFalse);
    });
  });
}

/// A provider keyed by its name whose image never arrives: enough to see
/// how the Reel tracks it.
class _PendingArt extends ImageProvider<_PendingArt> {
  _PendingArt(this.name);

  final String name;

  @override
  Future<_PendingArt> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_PendingArt key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);

  @override
  bool operator ==(Object other) => other is _PendingArt && other.name == name;

  @override
  int get hashCode => name.hashCode;
}
