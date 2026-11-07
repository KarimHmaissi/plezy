import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/reel/reel_card_view.dart';
import 'package:plezy/screens/reel/reel_deck_intro_view.dart';
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
import 'package:plezy/theme/mono_theme.dart';

import '../test_helpers/prefs.dart';
import 'clip_player_test.dart' show FakeClipEngine;

const _titles = ['Harbor Lights', 'Quiet Orchard', 'The Long Ferry', 'Salt and Signal', 'Lantern Street', 'Mill Road'];

ReelCardData _card(int i) => ReelCardData(
  title: ReelTitle(
    titleId: 't$i',
    groupKey: 'g$i',
    title: _titles[i],
    isShow: false,
    copies: [ReelCopy(serverId: 's1', ratingKey: '$i')],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: 't$i', groupKey: 'g$i'),
    seen: SeenState.unseen,
  ),
  best: IndexedTitle(
    id: 's1:$i',
    serverId: 's1',
    serverName: 'Server A',
    libraryKey: '1',
    libraryTitle: 'Films',
    ratingKey: '$i',
    type: 'movie',
    title: _titles[i],
    genres: '',
    countries: '',
    directors: '',
    writers: '',
    cast: '',
    collections: '',
    groupKey: 'g$i',
    summary: '',
  ),
);

const _line = '4 films, 2 shows arrived. 3 worth a look.';

/// The intro slot as the controller builds it: the first five cards, none
/// with metadata yet (no poster to load).
ReelSlot _slot() =>
    ReelSlot.intro(const ReelDeckIntro(line: _line), [for (var i = 0; i < 5; i++) ReelIntroPreview(_card(i), null)]);

class _Servers implements ReelServers {
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => const [];

  @override
  String? clipUrl(String serverId, String partKey) => null;
}

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async =>
      MediaItem(id: ratingKey, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'x', serverId: serverId);

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) => item(serverId, ratingKey);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

class _IntroDeck extends ReelDeck {
  @override
  String get id => 'new-this-week';
  @override
  String get name => 'New this week';
  @override
  bool get keepsSeen => false;
  @override
  bool get raw => true;
  @override
  ReelDeckIntro? get intro => const ReelDeckIntro(line: _line);

  @override
  Future<List<ReelCardData>> load() async => [_card(0), _card(1)];
}

void main() {
  Future<void> show(WidgetTester tester, Size size, Widget child) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: Scaffold(body: child),
      ),
    );
    // The chip, the line and the posters rise in one after another.
    await tester.pumpAndSettle();
  }

  testWidgets('TV: the deck, its line, its first five cards and the keys', (tester) async {
    await show(
      tester,
      const Size(1920, 1080),
      ReelDeckIntroView(deckId: 'new-this-week', deckName: 'New this week', slot: _slot(), tv: true),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('New this week'), findsOneWidget);
    expect(find.text(_line), findsOneWidget);
    for (final title in _titles.take(5)) {
      expect(find.text(title), findsOneWidget, reason: 'no metadata yet: the title stands in for the poster');
    }
    expect(find.text('OK or ↓ first card  ·  → next deck'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing, reason: "the TV's keys start it, not a button");
  });

  testWidgets('phone, at a narrow width: it fits, and Start goes to the first card', (tester) async {
    var started = 0;
    await show(
      tester,
      const Size(360, 740),
      ReelDeckIntroView(
        deckId: 'new-this-week',
        deckName: 'New this week',
        slot: _slot(),
        tv: false,
        onStart: () => started++,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text(_line), findsOneWidget);
    expect(find.text('Or swipe up for the first card'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    expect(started, 1);
  });

  testWidgets('with reduced motion everything is there at once', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true, size: Size(360, 740)),
          child: Scaffold(
            body: ReelDeckIntroView(deckId: 'new-this-week', deckName: 'New this week', slot: _slot(), tv: false),
          ),
        ),
      ),
    );
    await tester.pump();
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(of: find.text(_line), matching: find.byType(FadeTransition)),
    );
    expect(fades.every((f) => f.opacity.value == 1), isTrue);
  });

  testWidgets("TV: the card view shows the deck's intro card for the intro slot", (tester) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    final db = ForkDatabase.memory();
    addTearDown(db.close);
    final settings = LocalCustomisationStore(db);
    final store = ReelStore(database: () async => db, settings: () async => settings);
    final c = ReelController(
      decks: [_IntroDeck()],
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
    addTearDown(c.dispose);
    await tester.runAsync(c.start);
    expect(c.current.kind, ReelSlotKind.intro);
    await show(
      tester,
      const Size(1920, 1080),
      ListenableBuilder(
        listenable: c,
        builder: (context, _) => ReelCardView(controller: c, slot: c.current, tv: true, onReplay: () {}),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ReelDeckIntroView), findsOneWidget);
    expect(find.text(_line), findsOneWidget);
    expect(find.text('Harbor Lights'), findsOneWidget);
  });
}
