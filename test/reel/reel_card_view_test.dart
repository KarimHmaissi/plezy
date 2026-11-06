// The fake engine's controllers belong to the engine for the whole test.
// ignore_for_file: close_sinks
import 'dart:async';

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
import 'package:plezy/utils/layout_constants.dart';
import 'package:plezy/widgets/fork_motion_widgets.dart';
import 'package:plezy/widgets/stat_chip.dart';
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
    summary: 'A lighthouse keeper finds a map in the fog and follows it out along the coast.',
  );

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

/// Holds every item until [land] (V2-26); a long summary fills the
/// spotlight's four lines, and [missing] answers null (the request failed).
class _GatedMedia implements ReelMedia {
  final Completer<void> _gate = Completer<void>();
  bool missing = false;

  void land() => _gate.complete();

  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async {
    await _gate.future;
    if (missing) return null;
    return MediaItem(
      id: ratingKey,
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: _titles[ratingKey],
      year: 2020,
      contentRating: 'PG',
      summary: List.filled(
        6,
        'A lighthouse keeper finds a map in the fog and follows it out along the coast.',
      ).join(' '),
    );
  }

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

class _Deck extends ReelDeck {
  _Deck(this.ids, {this.cardOf = _card});

  final List<String> ids;
  final ReelCardData Function(String id) cardOf;

  @override
  String get id => 'a';
  @override
  String get name => 'Server A picks';
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;
  @override
  Future<List<ReelCardData>> load() async => [for (final i in ids) cardOf(i)];
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

/// An anime show with a deck chip, a seen badge and a long why line: the
/// tallest extras block the TV card draws.
ReelCardData _animeCard(String id) => ReelCardData(
  title: ReelTitle(
    titleId: 't$id',
    groupKey: 'g$id',
    title: _titles[id]!,
    isShow: true,
    anime: true,
    tvdbId: 1,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: 't$id', groupKey: 'g$id'),
    seen: const SeenState(kind: SeenKind.inProgress),
  ),
  best: _card(id).best,
  chip: '#1 show this week',
  why:
      'Because the harbour towns and slow storms of your recent watches run all the way through this one, '
      'and its opening is the one people keep coming back to.',
);

Future<Map<int, Map<String, dynamic>>> _animeThemes(List<int> ids) async => {
  101: {
    'animethemes': [
      {
        'type': 'OP',
        'sequence': 1,
        'animethemeentries': [
          {
            'episodes': '1-12',
            'videos': [
              {'id': 9, 'link': 'https://v.animethemes.moe/Show-OP1.webm', 'nc': true, 'resolution': 1080},
            ],
          },
        ],
      },
    ],
  },
};

const _a = ClipSource(uri: 'https://cdn.example/a.mp4', origin: ClipOrigin.plexExtra);
const _b = ClipSource(uri: 'https://cdn.example/b.mp4', origin: ClipOrigin.plexExtra);

ReelController _controller(ForkDatabase db, ReelDeck deck, void Function(FakeClipEngine) onEngine, {ReelMedia? media}) {
  resetSharedPreferencesForTest();
  SettingsService.resetForTesting();
  LocaleSettings.setLocaleSync(AppLocale.en);
  final settings = LocalCustomisationStore(db);
  final store = ReelStore(database: () async => db, settings: () async => settings);
  return ReelController(
    decks: [deck],
    resolver: ClipResolver(
      servers: _Servers(),
      store: store,
      aniList: (t) async => t.tvdbId == 1 ? 101 : null,
      animeThemes: _animeThemes,
    ),
    clips: ClipPlayer(
      engine: () {
        final e = FakeClipEngine();
        onEngine(e);
        return e;
      },
    ),
    store: store,
    media: media ?? _Media(),
    onWatch: (_, {required onTv}) async => true,
    addToWatchlist: (_) async => true,
  );
}

/// The TV card at [size] logical pixels (960 x 540 is the 0.85 scale clamp).
Future<void> _pumpTv(
  WidgetTester tester,
  ReelController c, {
  Size size = const Size(1920, 1080),
  bool reduceMotion = false,
}) async {
  await tester.runAsync(SettingsService.getInstance);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(c.start);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
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
      db = ForkDatabase.memory();
      c = _controller(db, _Deck(['1', '2', '3']), (e) => engine = e);
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

    Future<void> pump(WidgetTester tester) => _pumpTv(tester, c);

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

  group('TV info block (V2-25)', () {
    late ForkDatabase db;
    late ReelController c;
    late FakeClipEngine engine;

    setUp(() async {
      db = ForkDatabase.memory();
      c = _controller(db, _Deck(['1', '2'], cardOf: _animeCard), (e) => engine = e);
    });

    tearDown(() async {
      c.dispose();
      await db.close();
    });

    TvSpotlightBackground spotlight(WidgetTester tester) =>
        tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground));

    Finder extras(String id) => find.byKey(ValueKey('extras:t$id'));

    Future<void> hold(WidgetTester tester) async {
      for (var i = 0; i < 4 && c.clips.phase.value != ClipPhase.held; i++) {
        engine.completedCtl.add(true);
        await tester.pump();
      }
      expect(c.clips.phase.value, ClipPhase.held);
      await tester.pumpAndSettle();
    }

    testWidgets('the clip kind is on the metadata line and the credit has its own line', (tester) async {
      await _pumpTv(tester, c);
      engine.firstFrameCtl.add(null);
      await tester.pumpAndSettle();

      expect(spotlight(tester).metadataTrailing, isNotNull);
      final kind = find.byKey(const ValueKey('reel-clip-kind'));
      expect(find.descendant(of: find.byType(TvSpotlightBackground), matching: kind), findsOneWidget);
      expect(find.descendant(of: kind, matching: find.text('Opening 1')), findsOneWidget);
      expect(find.descendant(of: extras('1'), matching: find.text('Opening 1')), findsNothing);

      final credit = find.text('Theme via AnimeThemes');
      expect(credit, findsOneWidget);
      expect(find.ancestor(of: credit, matching: find.byType(Wrap)), findsNothing);
      expect(find.text('#1 show this week'), findsOneWidget);
      expect(find.text('Watching'), findsOneWidget);
    });

    testWidgets('the chips scale with the TV scale, at the compact spotlight metadata size', (tester) async {
      await _pumpTv(tester, c, size: const Size(960, 540));
      engine.firstFrameCtl.add(null);
      await tester.pumpAndSettle();
      final chips = tester.widgetList<StatChip>(find.byType(StatChip));
      expect(chips, hasLength(2));
      for (final chip in chips) {
        expect(chip.fontSize, closeTo(TvSpotlightBackground.metadataFontSize(0.85, compact: true), 1e-9));
      }
    });

    testWidgets('a held anime card at the 0.85 clamp fits, with the info block right above the extras', (tester) async {
      const scale = 0.85;
      await _pumpTv(tester, c, size: const Size(960, 540));
      engine.firstFrameCtl.add(null);
      await tester.pumpAndSettle();
      final playingBottom = spotlight(tester).contentBottom;
      // The measured height is the drawn one: the info block ends 20*scale
      // above the extras' real top.
      expect(540 - playingBottom + 20 * scale, closeTo(tester.getRect(extras('1')).top, 0.5));

      await hold(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Replay'), findsOneWidget);
      final heldBottom = spotlight(tester).contentBottom;
      expect(heldBottom - playingBottom, closeTo(58 * scale, 1e-9));
      final box = tester.getRect(extras('1'));
      expect(540 - heldBottom + 20 * scale, closeTo(box.top, 0.5));
      expect(box.bottom, closeTo(540 - 24 * scale, 0.5));
      expect(tester.getRect(find.text('Replay')).bottom, lessThanOrEqualTo(box.bottom));
    });

    testWidgets('the extras cross-fade with the card instead of cutting', (tester) async {
      await _pumpTv(tester, c);
      engine.firstFrameCtl.add(null);
      await tester.pumpAndSettle();
      expect(extras('1'), findsOneWidget);

      await tester.runAsync(() => c.step(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(extras('1'), findsOneWidget, reason: 'the old block is still fading out');
      expect(extras('2'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(extras('1'), findsNothing);
      expect(extras('2'), findsOneWidget);
    });

    testWidgets('with animations off, the card change and Replay land at once', (tester) async {
      await _pumpTv(tester, c, size: const Size(960, 540), reduceMotion: true);
      engine.firstFrameCtl.add(null);
      await tester.pumpAndSettle();
      await hold(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Replay'), findsOneWidget);
      expect(find.byType(AnimatedSize), findsNothing);

      await tester.runAsync(() => c.step(1));
      await tester.pump();
      await tester.pump();
      expect(extras('1'), findsNothing);
      expect(extras('2'), findsOneWidget);
    });
  });
  group('TV title before the metadata lands (V2-26)', () {
    late ForkDatabase db;
    late ReelController c;
    late FakeClipEngine engine;
    late _GatedMedia media;

    setUp(() async {
      db = ForkDatabase.memory();
      media = _GatedMedia();
      c = _controller(db, _Deck(['1', '2']), (e) => engine = e, media: media);
    });

    tearDown(() async {
      c.dispose();
      await db.close();
    });

    Finder inSpotlight(Finder f) => find.descendant(of: find.byType(TvSpotlightBackground), matching: f);
    Finder title() => inSpotlight(find.text('Harbor Lights'));
    final skeleton = find.byKey(const ValueKey('spotlight-pending-skeleton'));

    /// Starts the Reel with the item held back (start waits for the first
    /// card's resolve, so it is left running).
    Future<void> pumpPending(WidgetTester tester) async {
      await tester.runAsync(SettingsService.getInstance);
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        unawaited(c.start());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
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
      expect(c.current.kind, ReelSlotKind.card);
      expect(c.current.item, isNull);
    }

    Future<void> land(WidgetTester tester) async {
      media.land();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(c.current.resolved, isTrue);
      await tester.pump();
    }

    testWidgets("the title waits in the spotlight's own logo slot over a shimmering skeleton", (tester) async {
      await pumpPending(tester);
      final spot = tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground));
      expect(spot.pendingTitle, 'Harbor Lights');
      expect(spot.pendingSkeleton, isTrue);
      expect(title(), findsOneWidget);
      expect(skeleton, findsOneWidget);
      expect(
        tester.widget<ForkShimmer>(find.ancestor(of: skeleton, matching: find.byType(ForkShimmer))).active,
        isTrue,
      );
      // The title's frame is the spotlight's logo slot, inside its info region.
      final slot = tester.getRect(find.ancestor(of: title(), matching: find.byType(SizedBox)).first);
      expect(
        slot.height,
        closeTo(TvLayoutConstants.heroLogoHeight * TvLayoutConstants.scaleOf(tester.element(title())), 0.5),
      );
      expect(slot.left, closeTo(TvLayoutConstants.horizontalInset, 0.5));
    });

    testWidgets('the metadata lands in place: the title does not move, one cross-fade', (tester) async {
      await pumpPending(tester);
      final before = tester.getRect(title());

      await land(tester);
      await tester.pump(const Duration(milliseconds: 100));
      // Mid cross-fade, the skeleton block and the item's block share the frame.
      expect(title(), findsNWidgets(2));
      expect(skeleton, findsOneWidget);
      for (final e in title().evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        expect(r.topLeft.dx, closeTo(before.left, 0.5));
        expect(r.topLeft.dy, closeTo(before.top, 0.5));
      }
      expect(find.text('PG'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
      expect(title(), findsOneWidget);
      expect(skeleton, findsNothing);
      expect(tester.getRect(title()).topLeft, offsetMoreOrLessEquals(before.topLeft, epsilon: 0.5));
    });

    testWidgets('an item that never lands keeps the title and drops the skeleton', (tester) async {
      media.missing = true;
      await pumpPending(tester);
      await land(tester);
      await tester.pumpAndSettle();
      expect(c.current.item, isNull);
      expect(title(), findsOneWidget);
      expect(skeleton, findsNothing);
      expect(tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground)).pendingSkeleton, isFalse);
    });

    testWidgets('no placeholder title outside the spotlight', (tester) async {
      await pumpPending(tester);
      expect(find.text('Harbor Lights'), findsOneWidget);
      await land(tester);
      await tester.pumpAndSettle();
      expect(find.text('Harbor Lights'), findsOneWidget);
      expect(title(), findsOneWidget);
      engine.firstFrameCtl.add(null);
      await tester.pumpAndSettle();
    });
  });
}
