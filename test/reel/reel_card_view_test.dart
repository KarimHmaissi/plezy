// The fake engine's controllers belong to the engine for the whole test.
// ignore_for_file: close_sinks
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/i18n/strings.g.dart';
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
import 'package:plezy/widgets/tv_spotlight_background.dart';

import '../test_helpers/prefs.dart';
import 'clip_player_test.dart' show FakeClipEngine;

const _titles = {'1': 'Harbor Lights', '2': 'Paper Moons', '3': 'The Quiet Orchard'};

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
    title: _titles[ratingKey],
    year: 2020,
  );

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

class _Deck extends ReelDeck {
  _Deck(this.ids);

  final List<String> ids;

  @override
  String get id => 'a';
  @override
  String get name => 'Server A picks';
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
    title: _titles[id]!,
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
    title: _titles[id]!,
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

const _a = ClipSource(uri: 'https://cdn.example/a.mp4', origin: ClipOrigin.plexExtra);
const _b = ClipSource(uri: 'https://cdn.example/b.mp4', origin: ClipOrigin.plexExtra);

void main() {
  group('ReelCardView.clipState (V2-01)', () {
    test("only this card's own clip, once on screen, takes the artwork away", () {
      final s = ReelCardView.clipState(clip: _b, onScreen: _b, phase: ClipPhase.playing, isCurrent: true);
      expect(s.showingClip, isTrue);
      expect(s.behind, isFalse);
    });

    test("the card before's clip still on screen: no clip shown, and the text waits", () {
      final s = ReelCardView.clipState(clip: _b, onScreen: _a, phase: ClipPhase.playing, isCurrent: true);
      expect(s.showingClip, isFalse);
      expect(s.behind, isTrue);
      expect(s.artDelay, ReelArtCover.clipGrace);
    });

    test('opening with nothing on screen: the text shows, the artwork is held back', () {
      final s = ReelCardView.clipState(clip: _b, onScreen: null, phase: ClipPhase.loading, isCurrent: true);
      expect(s.showingClip, isFalse);
      expect(s.behind, isFalse);
      expect(s.artDelay, ReelArtCover.clipGrace);
    });

    test('an AI card or a failed clip shows the artwork at once', () {
      final ai = ReelCardView.clipState(clip: null, onScreen: _a, phase: ClipPhase.paused, isCurrent: true);
      expect(ai.showingClip, isFalse);
      expect(ai.behind, isFalse);
      expect(ai.artDelay, Duration.zero);
      final failed = ReelCardView.clipState(clip: _b, onScreen: _b, phase: ClipPhase.failed, isCurrent: true);
      expect(failed.showingClip, isFalse);
      expect(failed.behind, isFalse);
      expect(failed.artDelay, Duration.zero);
    });

    test('a held clip stays on screen and offers Replay', () {
      final s = ReelCardView.clipState(clip: _b, onScreen: _b, phase: ClipPhase.held, isCurrent: true);
      expect(s.showingClip, isTrue);
      expect(s.held, isTrue);
    });
  });

  group('ReelArtCover', () {
    Future<void> pumpCover(WidgetTester tester, {required bool cover, required Duration delay}) => tester.pumpWidget(
      ReelArtCover(
        cover: cover,
        delay: delay,
        builder: (context, show) => Text(show ? 'art' : 'clip', textDirection: TextDirection.ltr),
      ),
    );

    testWidgets('holds the artwork back for the delay, then shows it', (tester) async {
      await pumpCover(tester, cover: false, delay: ReelArtCover.clipGrace);
      await pumpCover(tester, cover: true, delay: ReelArtCover.clipGrace);
      expect(find.text('clip'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 190));
      expect(find.text('clip'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('art'), findsOneWidget);
    });

    testWidgets('a clip that lands inside the delay never shows the artwork', (tester) async {
      await pumpCover(tester, cover: false, delay: ReelArtCover.clipGrace);
      await pumpCover(tester, cover: true, delay: ReelArtCover.clipGrace);
      await tester.pump(const Duration(milliseconds: 170));
      await pumpCover(tester, cover: false, delay: ReelArtCover.clipGrace);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('clip'), findsOneWidget);
    });

    testWidgets('no delay (an AI card, a failure) shows it at once', (tester) async {
      await pumpCover(tester, cover: false, delay: ReelArtCover.clipGrace);
      await pumpCover(tester, cover: true, delay: ReelArtCover.clipGrace);
      await pumpCover(tester, cover: true, delay: Duration.zero);
      expect(find.text('art'), findsOneWidget);
    });
  });

  group('TV card change (V2-01)', () {
    late ForkDatabase db;
    late ReelController c;
    late FakeClipEngine engine;

    setUp(() async {
      resetSharedPreferencesForTest();
      SettingsService.resetForTesting();
      LocaleSettings.setLocaleSync(AppLocale.en);
      db = ForkDatabase.memory();
      final settings = LocalCustomisationStore(db);
      final store = ReelStore(database: () async => db, settings: () async => settings);
      c = ReelController(
        decks: [
          _Deck(['1', '2', '3']),
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
        onWatch: (_, {required onTv}) async => true,
        addToWatchlist: (_) async => true,
      );
    });

    tearDown(() async {
      c.dispose();
      await db.close();
    });

    double artOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find.descendant(of: find.byType(TvSpotlightBackground), matching: find.byType(AnimatedOpacity)).first,
        )
        .opacity;

    Future<void> pump(WidgetTester tester) async {
      await tester.runAsync(SettingsService.getInstance);
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(c.start);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: ListenableBuilder(
                listenable: c,
                builder: (context, _) => ReelCardView(controller: c, slot: c.current, tv: true, onReplay: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> nextCard(WidgetTester tester) async {
      await tester.runAsync(() => c.step(1));
      await tester.pump();
    }

    testWidgets('a quick first frame never shows the artwork between two clips', (tester) async {
      await pump(tester);
      engine.firstFrameCtl.add(null);
      await tester.pump(const Duration(milliseconds: 400));
      expect(artOpacity(tester), 0);
      expect(find.text('Harbor Lights'), findsWidgets);

      await nextCard(tester);
      // The new title is up at once, with no art over the opening clip.
      expect(c.clips.onScreen.value, isNull);
      expect(find.text('Paper Moons'), findsWidgets);
      expect(artOpacity(tester), 0);
      await tester.pump(const Duration(milliseconds: 150));
      expect(artOpacity(tester), 0);
      engine.firstFrameCtl.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(artOpacity(tester), 0, reason: 'a preloaded start never blinks the art');
    });

    testWidgets('a slow start shows the artwork after the grace', (tester) async {
      await pump(tester);
      engine.firstFrameCtl.add(null);
      await tester.pump(const Duration(milliseconds: 400));

      await nextCard(tester);
      await tester.pump(ReelArtCover.clipGrace + const Duration(milliseconds: 10));
      expect(artOpacity(tester), 1);
      engine.firstFrameCtl.add(null);
      await tester.pump();
      expect(artOpacity(tester), 0);
    });
  });
}
