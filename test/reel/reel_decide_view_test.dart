import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/reel/reel_card_view.dart';
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

import '../test_helpers/prefs.dart';
import 'clip_player_test.dart' show FakeClipEngine;

class _Servers implements ReelServers {
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => const [];

  @override
  String? clipUrl(String serverId, String partKey) => null;
}

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async => MediaItem(
    id: ratingKey,
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: _titles[ratingKey] ?? 'Title $ratingKey',
    year: 2021,
    serverId: serverId,
  );

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

const _titles = {'1': 'Harbor Lights', '7': 'Quiet Orchard', '8': 'The Long Ferry', '9': 'Salt and Signal'};

class _Deck extends ReelDeck {
  @override
  String get id => 'a';
  @override
  String get name => 'Deck a';
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;

  @override
  Future<List<ReelCardData>> load() async => [
    ReelCardData(
      title: ReelTitle(
        titleId: 't1',
        groupKey: 'g1',
        title: 'Harbor Lights',
        isShow: false,
        copies: [ReelCopy(serverId: 's1', ratingKey: '1')],
      ),
      facts: TitleFacts(
        ref: TitleRef(id: 't1', groupKey: 'g1'),
        seen: SeenState.unseen,
      ),
      best: IndexedTitle(
        id: 's1:1',
        serverId: 's1',
        serverName: 'S',
        libraryKey: '1',
        libraryTitle: 'Films',
        ratingKey: '1',
        type: 'movie',
        title: 'Harbor Lights',
        genres: '',
        countries: '',
        directors: '',
        writers: '',
        cast: '',
        collections: '',
        groupKey: 'g1',
        summary: '',
      ),
    ),
  ];
}

void main() {
  late ForkDatabase db;
  late ReelStore store;
  late ReelController c;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    c = ReelController(
      decks: [_Deck()],
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
    );
  });

  tearDown(() async {
    c.dispose();
    await db.close();
  });

  /// Three fresh Saves, then the end of the deck: Tonight's picks.
  Future<void> onDecide(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (final (i, id) in ['7', '8', '9'].indexed) {
        await store.savePick(
          ReelPick(
            titleId: 't$id',
            groupKey: 'g$id',
            serverId: 's1',
            ratingKey: id,
            title: _titles[id]!,
            at: DateTime.now().toUtc().subtract(Duration(minutes: 3 - i)),
          ),
        );
      }
      await c.start();
      await c.step(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(c.current.kind, ReelSlotKind.decide);
  }

  Future<void> show(WidgetTester tester, Size size, {required bool tv}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var watched = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (context, _) =>
                ReelCardView(controller: c, slot: c.current, tv: tv, onReplay: () {}, onWatch: () => watched++),
          ),
        ),
      ),
    );
    // The posters deal in one after another.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Watch'));
    expect(watched, 1);
  }

  testWidgets('TV: the posters under the chosen pick, the newest first, and the keys to use', (tester) async {
    await onDecide(tester);
    await show(tester, const Size(1920, 1080), tv: true);
    expect(tester.takeException(), isNull);
    expect(find.text("Tonight's picks"), findsOneWidget);
    expect(find.text('← → choose  ·  OK watch  ·  ↓ keep going'), findsOneWidget);
    final posters = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('decide:t'),
    );
    expect(tester.widgetList(posters).map((w) => (w.key! as ValueKey<String>).value), [
      'decide:t9',
      'decide:t8',
      'decide:t7',
    ]);
    expect(c.current.chosen?.pick.title, 'Salt and Signal');

    c.movePick(1);
    await tester.pumpAndSettle();
    expect(c.current.chosen?.pick.title, 'The Long Ferry');
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone, at a narrow width: it fits, with Watch full width', (tester) async {
    await onDecide(tester);
    await show(tester, const Size(360, 740), tv: false);
    expect(tester.takeException(), isNull);
    expect(find.text('One for tonight?'), findsOneWidget);
    expect(find.text('Swipe up to keep going.'), findsOneWidget);
  });

  testWidgets('with no picks left it says so, and how to go on', (tester) async {
    await tester.runAsync(c.start);
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ReelCardView(controller: c, slot: const ReelSlot.decide([], 0), tv: true, onReplay: () {}),
      ),
    );
    expect(find.text('Nothing saved lately. Press ↓ to keep going.'), findsOneWidget);
  });
}
