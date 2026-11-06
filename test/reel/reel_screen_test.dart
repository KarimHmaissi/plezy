// The fake engine's controllers are closed with the test.
// ignore_for_file: close_sinks
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/reel/reel_card_view.dart';
import 'package:plezy/screens/reel/reel_screen.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';

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
  Future<MediaItem?> item(String serverId, String ratingKey) async =>
      MediaItem(id: ratingKey, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Harbor Lights', year: 2020);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

class _Deck extends ReelDeck {
  _Deck(this.ids);

  final List<String> ids;

  @override
  String get id => 'a';

  @override
  String get name => 'Deck A';

  @override
  bool get keepsSeen => true;

  @override
  bool get raw => true;

  @override
  Future<List<ReelCardData>> load() async => [for (final id in ids) _card(id)];
}

ReelCardData _card(String id) => ReelCardData(
  title: ReelTitle(
    titleId: 't$id',
    groupKey: 'g$id',
    title: 'Harbor Lights',
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
    title: 'Harbor Lights',
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

void main() {
  late ForkDatabase db;
  late ReelStore store;
  FakeClipEngine? engine;

  setUp(() async {
    // The TV card's backdrop reads its prefs during build.
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    engine = null;
  });

  tearDown(() async {
    TvDetectionService.debugSetAppleTVOverride(null);
    await db.close();
  });

  ReelController make() => ReelController(
    decks: [
      _Deck(['1', '2']),
    ],
    resolver: ClipResolver(
      servers: _Servers(),
      store: store,
      aniList: (_) async => null,
      animeThemes: (_) async => const {},
    ),
    clips: ClipPlayer(engine: () => engine = FakeClipEngine()),
    store: store,
    media: _Media(),
    onWatch: (_, {required onTv}) async => false,
    addToWatchlist: (_) async => true,
  );

  Future<GlobalKey<ReelScreenState>> pump(
    WidgetTester tester,
    Future<ReelController> Function(BuildContext) create, {
    bool offline = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<ReelScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ReelScreen(key: key, create: create, offline: offline),
        ),
      ),
    );
    return key;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('V2-60: a failed open shows a message with Retry, and Retry builds again', (tester) async {
    var calls = 0;
    final never = Completer<ReelController>();
    final key = await pump(tester, (_) {
      calls++;
      return calls == 1 ? Future.error(StateError('no servers yet')) : never.future;
    });
    key.currentState!.onTabShown();
    await settle(tester);
    expect(calls, 1);
    expect(find.text("The Reel didn't open"), findsOneWidget);
    expect(find.byType(ReelCurtain), findsNothing);

    await tester.tap(find.text('Retry'));
    await settle(tester);
    expect(calls, 2);
    expect(find.text("The Reel didn't open"), findsNothing);
    expect(find.byType(ReelCurtain), findsOneWidget);
  });

  testWidgets('V2-60: the tab shown again after a failed open tries again', (tester) async {
    var calls = 0;
    final key = await pump(tester, (_) {
      calls++;
      return Future.error(StateError('no servers yet'));
    });
    key.currentState!.onTabShown();
    await settle(tester);
    key.currentState!.onTabHidden();
    key.currentState!.onTabShown();
    await settle(tester);
    expect(calls, 2);
    expect(find.text("The Reel didn't open"), findsOneWidget);
  });

  testWidgets('V2-60: TV OK on the failed-open message is Retry', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    var calls = 0;
    final key = await pump(tester, (_) {
      calls++;
      return Future.error(StateError('no servers yet'));
    });
    key.currentState!.onTabShown();
    await settle(tester);
    key.currentState!.focusActiveTabIfReady();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(calls, 2);
  });

  testWidgets('V2-60: offline keeps the tab with a message and builds nothing until back online', (tester) async {
    var calls = 0;
    final never = Completer<ReelController>();
    Future<ReelController> create(BuildContext _) {
      calls++;
      return never.future;
    }

    final key = await pump(tester, create, offline: true);
    key.currentState!.onTabShown();
    await settle(tester);
    expect(find.text("You're offline"), findsOneWidget);
    expect(calls, 0);
    expect(find.byType(ReelCurtain), findsNothing);
  });

  testWidgets('V2-60: going offline while playing suspends the session, and coming back starts it', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    final c = make();
    final key = GlobalKey<ReelScreenState>();
    Widget app(bool offline) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: ReelScreen(key: key, create: (_) async => c, offline: offline),
      ),
    );
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(false));
    key.currentState!.onTabShown();
    await settle(tester);
    expect(c.active, isTrue);

    await tester.pumpWidget(app(true));
    await settle(tester);
    expect(c.active, isFalse);
    expect(engine?.disposed ?? true, isTrue);
    expect(find.text("You're offline"), findsOneWidget);

    await tester.pumpWidget(app(false));
    await settle(tester);
    expect(c.active, isTrue);
    expect(find.text("You're offline"), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('V2-60: TV inactive pauses without releasing; resumed plays on; paused releases', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    final c = make();
    final key = await pump(tester, (_) async => c);
    key.currentState!.onTabShown();
    await settle(tester);
    final e = engine!;
    e.firstFrameCtl.add(null);
    await tester.pump();
    expect(c.clips.phase.value, ClipPhase.playing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await settle(tester);
    expect(c.clips.phase.value, ClipPhase.paused);
    expect(e.calls.last, 'pause');
    expect(e.disposed, isFalse);
    expect(c.active, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(c.clips.phase.value, ClipPhase.playing);
    expect(e.calls.last, 'play');
    expect(identical(engine, e), isTrue, reason: 'no new core: the clip played on');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle(tester);
    expect(c.active, isFalse);
    expect(e.disposed, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(c.active, isTrue);
    expect(identical(engine, e), isFalse, reason: 'a released core is rebuilt on resume');
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });
}
