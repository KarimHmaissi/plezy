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
import 'package:plezy/screens/reel/reel_lean_back.dart';
import 'package:plezy/screens/reel/reel_sheet.dart';
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
import 'package:plezy/theme/fork_motion.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/layout_constants.dart';
import 'package:plezy/widgets/fork_motion_widgets.dart';
import 'package:plezy/widgets/media_progress_bar.dart';
import 'package:plezy/widgets/stat_chip.dart';
import 'package:plezy/widgets/tv_spotlight_background.dart';
import 'package:plezy/widgets/video_controls/widgets/transport_feedback_indicator.dart';

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

/// A deck with its own id and name whose load can wait on [gate] and
/// throw while [fails] is set (V2-27).
class _SwitchDeck extends ReelDeck {
  _SwitchDeck(this.id, this.name, this.ids);

  @override
  final String id;
  @override
  final String name;
  final List<String> ids;
  Completer<void>? gate;
  bool fails = false;

  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;
  @override
  Future<List<ReelCardData>> load() async {
    await gate?.future;
    if (fails) throw StateError('server unreachable');
    return [for (final i in ids) _card(i)];
  }
}

ReelController _controller(
  ForkDatabase db,
  ReelDeck deck,
  void Function(FakeClipEngine) onEngine, {
  ReelMedia? media,
  List<ReelDeck> more = const [],
}) {
  resetSharedPreferencesForTest();
  SettingsService.resetForTesting();
  LocaleSettings.setLocaleSync(AppLocale.en);
  final settings = LocalCustomisationStore(db);
  final store = ReelStore(database: () async => db, settings: () async => settings);
  return ReelController(
    decks: [deck, ...more],
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
  ReelLeanBack? leanBack,
  ReelOkAction okAction = ReelOkAction.watch,
  ThemeData? theme,
}) async {
  await tester.runAsync(SettingsService.getInstance);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(c.start);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: theme ?? ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Stack(
              fit: StackFit.expand,
              children: [
                ReelCardView(
                  controller: c,
                  slot: c.current,
                  tv: true,
                  onReplay: () {},
                  leanBack: leanBack,
                  okAction: okAction,
                ),
                if (leanBack != null) ReelPauseFeedback(controller: c, leanBack: leanBack),
              ],
            ),
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
      // Replay and its focus ring (V2-28).
      expect(heldBottom - playingBottom, closeTo(66 * scale, 1e-9));
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

  group('TV deck switch (V2-27)', () {
    late ForkDatabase db;
    late ReelController c;

    setUp(() {
      db = ForkDatabase.memory();
    });

    tearDown(() async {
      c.dispose();
      await db.close();
    });

    Future<void> pumpView(WidgetTester tester, {Size size = const Size(1920, 1080), bool reduceMotion = false}) async {
      await tester.runAsync(SettingsService.getInstance);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
                builder: (context, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ReelCardView(controller: c, slot: c.current, tv: true, onReplay: () {}),
                    ReelDeckStrip(controller: c),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    final skeleton = find.byKey(const ValueKey('spotlight-pending-skeleton'));

    testWidgets('a deck still loading is the spotlight skeleton, not a spinner', (tester) async {
      final deck = _SwitchDeck('a', 'Deck A', ['1'])..gate = Completer<void>();
      c = _controller(db, deck, (_) {});
      await tester.runAsync(SettingsService.getInstance);
      await tester.runAsync(() async {
        unawaited(c.start());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await pumpView(tester);
      expect(c.current.kind, ReelSlotKind.loading);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(ReelTvSkeleton), findsOneWidget);
      final spot = tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground));
      expect(spot.item, isNull);
      expect(spot.pendingTitle, isEmpty);
      // The title slot is a bar too, inside the one shimmer.
      expect(skeleton, findsOneWidget);
      expect(
        tester.widget<ForkShimmer>(find.ancestor(of: skeleton, matching: find.byType(ForkShimmer))).active,
        isTrue,
      );

      await tester.runAsync(() async {
        deck.gate!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(c.current.kind, ReelSlotKind.card);
      // The skeleton fades out over the card with the sheet motion.
      await tester.pump(ForkMotion.sheetIn ~/ 2);
      expect(find.byType(ReelTvSkeleton), findsOneWidget);
      await tester.pump(ForkMotion.sheetIn);
      expect(find.byType(ReelTvSkeleton), findsNothing);
      expect(find.text('Harbor Lights'), findsWidgets);
    });

    testWidgets('a deck that failed to load says so, and Try again loads it', (tester) async {
      final deck = _SwitchDeck('a', 'Deck A', ['1'])..fails = true;
      c = _controller(db, deck, (_) {});
      await tester.runAsync(SettingsService.getInstance);
      await tester.runAsync(c.start);
      await pumpView(tester, reduceMotion: true);
      expect(c.current.kind, ReelSlotKind.failed);
      expect(find.text("Couldn't load Deck A"), findsOneWidget);
      expect(find.textContaining('Press OK to try again'), findsOneWidget);
      expect(find.textContaining('Nothing in'), findsNothing);

      deck.fails = false;
      await tester.runAsync(() async {
        tester
            .widget<ButtonStyleButton>(
              find.ancestor(
                of: find.text('Try again'),
                matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
              ),
            )
            .onPressed!();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(c.current.card?.id, 't1');
      expect(find.text("Couldn't load Deck A"), findsNothing);
    });

    testWidgets("an empty deck shows that deck's own icon", (tester) async {
      c = _controller(db, _SwitchDeck('anime-openings', 'Openings', const []), (_) {});
      await tester.runAsync(SettingsService.getInstance);
      await tester.runAsync(c.start);
      await pumpView(tester, reduceMotion: true);
      expect(find.text('Nothing in Openings yet'), findsOneWidget);
      expect(find.byIcon(reelDeckIcon('anime-openings')), findsOneWidget);
    });

    /// Three decks, never started: the strip is driven as the controller
    /// drives it on a switch (the timing is covered in the controller test).
    List<ReelDeck> threeDecks() => [
      _SwitchDeck('for-you', 'For You', ['1']),
      _SwitchDeck('anime-openings', 'Openings', ['2']),
      _SwitchDeck('most-watched', 'Most watched', ['3']),
    ];

    testWidgets('the strip reads previous, current and next, inside the overscan margin, in the TV scale', (
      tester,
    ) async {
      final decks = threeDecks();
      c = _controller(db, decks.first, (_) {}, more: decks.skip(1).toList());
      const size = Size(960, 540);
      await pumpView(tester, size: size);
      c.deckStrip.value = ReelDeckStripState(previous: decks[0], current: decks[1], next: decks[2]);
      await tester.pump();
      await tester.pump(ForkMotion.sheetIn);
      expect(find.text('‹  For You'), findsOneWidget);
      expect(find.text('Openings'), findsOneWidget);
      expect(find.text('Most watched  ›'), findsOneWidget);

      final strip = find.byKey(const ValueKey('reel-deck-strip:anime-openings'));
      final rect = tester.getRect(strip);
      expect(rect.top, closeTo(size.height * ReelDeckStrip.overscan, 0.5));
      expect(rect.right, closeTo(size.width * (1 - ReelDeckStrip.overscan), 0.5));
      expect(rect.left, greaterThanOrEqualTo(size.width * ReelDeckStrip.overscan - 0.5));

      final scale = TvLayoutConstants.scaleForSize(size);
      final icon = tester.widget<Icon>(find.descendant(of: strip, matching: find.byType(Icon)));
      expect(icon.icon, reelDeckIcon('anime-openings'));
      expect(icon.size, closeTo(20 * scale, 0.01));
    });

    testWidgets('the strip rises in with the sheet motion and leaves when cleared', (tester) async {
      final decks = threeDecks();
      c = _controller(db, decks.first, (_) {}, more: decks.skip(1).toList());
      await pumpView(tester);
      c.deckStrip.value = ReelDeckStripState(current: decks[1], next: decks[2]);
      await tester.pump();
      final strip = find.byKey(const ValueKey('reel-deck-strip:anime-openings'));
      const restingTop = 1080 * ReelDeckStrip.overscan;
      await tester.pump(ForkMotion.sheetIn ~/ 4);
      expect(tester.getRect(strip).top, greaterThan(restingTop + 1), reason: 'still rising');
      await tester.pump(ForkMotion.sheetIn);
      expect(tester.getRect(strip).top, closeTo(restingTop, 0.5));
      expect(find.textContaining('‹'), findsNothing, reason: 'no previous deck given');

      c.deckStrip.value = null;
      await tester.pump();
      await tester.pump(ForkMotion.sheetOut + const Duration(milliseconds: 20));
      expect(strip, findsNothing);
    });

    testWidgets('with animations off the strip is placed at once', (tester) async {
      final decks = threeDecks();
      c = _controller(db, decks.first, (_) {}, more: decks.skip(1).toList());
      await pumpView(tester, reduceMotion: true);
      c.deckStrip.value = ReelDeckStripState(previous: decks[0], current: decks[1], next: decks[2]);
      await tester.pump();
      final strip = find.byKey(const ValueKey('reel-deck-strip:anime-openings'));
      expect(tester.getRect(strip).top, closeTo(1080 * ReelDeckStrip.overscan, 0.5));
    });
  });

  group('TV lean back (V2-28)', () {
    late ForkDatabase db;
    late ReelController c;
    late FakeClipEngine engine;
    late ReelLeanBack lb;

    setUp(() async {
      db = ForkDatabase.memory();
      c = _controller(db, _Deck(['1', '2'], cardOf: _animeCard), (e) => engine = e);
      lb = ReelLeanBack();
    });

    tearDown(() async {
      lb.dispose();
      c.dispose();
      await db.close();
    });

    Finder extras(String id) => find.byKey(ValueKey('extras:t$id'));

    /// The opacity [finder] is faded to (its nearest [AnimatedOpacity]).
    AnimatedOpacity fadeOf(WidgetTester tester, Finder finder) =>
        tester.widget<AnimatedOpacity>(find.ancestor(of: finder, matching: find.byType(AnimatedOpacity)).first);

    final summary = find.byKey(const ValueKey('spotlight-summary'));
    final scrim = find.byKey(const ValueKey('spotlight-side-scrim'));
    final hints = find.byKey(const ValueKey('reel-hints'));
    const why = 'Because the harbour towns';

    /// The card's clip on screen and playing, as ReelScreen wires it.
    Future<void> playing(WidgetTester tester, {int session = 1, Size size = const Size(1920, 1080)}) async {
      lb.begin(session: session);
      await _pumpTv(tester, c, leanBack: lb, size: size);
      engine.firstFrameCtl.add(null);
      lb.playing = c.clips.phase.value == ClipPhase.playing;
      await tester.pumpAndSettle();
    }

    testWidgets('after 6 s of play the summary, why line, chips and hints fade in place; a key brings them back '
        'over 200 ms', (tester) async {
      await playing(tester);
      final title = tester.getRect(find.text('Harbor Lights').first);
      final block = tester.getRect(extras('1'));
      expect(tester.widget<AnimatedOpacity>(summary).opacity, 1);

      await tester.pump(const Duration(seconds: 6));
      expect(lb.quiet, isTrue);
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(summary).opacity, 0);
      expect(tester.widget<AnimatedOpacity>(scrim).opacity, TvSpotlightBackground.quietScrim);
      expect(fadeOf(tester, find.text('#1 show this week')).opacity, 0);
      expect(fadeOf(tester, find.textContaining(why)).opacity, 0);
      expect(fadeOf(tester, hints).opacity, 0);
      // The title, the metadata line and the credit stay, and nothing moves.
      expect(
        find.ancestor(of: find.text('Theme via AnimeThemes'), matching: find.byType(AnimatedOpacity)),
        findsNothing,
      );
      expect(tester.getRect(find.text('Harbor Lights').first), title);
      expect(tester.getRect(extras('1')), block);

      lb.poke();
      await tester.pump();
      final back = tester.widget<AnimatedOpacity>(summary);
      expect(back.opacity, 1);
      expect(back.duration, const Duration(milliseconds: 200));
      expect(fadeOf(tester, hints).duration, const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<AnimatedOpacity>(scrim).opacity, 1);
      expect(fadeOf(tester, find.text('#1 show this week')).opacity, 1);
      expect(fadeOf(tester, hints).opacity, 1);
      lb.end();
    });

    testWidgets('a held clip is never quiet, and Replay is drawn focused', (tester) async {
      await playing(tester);
      for (var i = 0; i < 2; i++) {
        engine.completedCtl.add(true);
        await tester.pump();
      }
      expect(c.clips.phase.value, ClipPhase.held);
      lb.playing = c.clips.phase.value == ClipPhase.playing;
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(lb.quiet, isFalse);
      expect(tester.widget<AnimatedOpacity>(summary).opacity, 1);
      expect(find.text('Replay'), findsOneWidget);

      final ring = tester.widget<DecoratedBox>(find.byKey(const ValueKey('reel-replay-focus')));
      final border = (ring.decoration as BoxDecoration).border! as Border;
      final context = tester.element(find.text('Replay'));
      expect(border.top.color, Theme.of(context).colorScheme.primary);
      expect(border.top.width, 2.5);
      final button = tester.getRect(
        find.ancestor(of: find.text('Replay'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
      );
      final box = tester.getRect(find.byKey(const ValueKey('reel-replay-focus')));
      expect(box.contains(button.topLeft) && box.contains(button.bottomRight), isTrue);
      expect(button.top - box.top, greaterThan(2.5), reason: 'a gap between the ring and the button');
      lb.end();
    });

    testWidgets('from the fourth session the hints take no room until 10 s with no key', (tester) async {
      lb.begin(session: 4);
      await _pumpTv(tester, c, leanBack: lb);
      engine.firstFrameCtl.add(null);
      // Paused: the card stays up, so the hints can come in.
      await tester.runAsync(c.clips.pause);
      lb.playing = false;
      await tester.pumpAndSettle();
      expect(hints, findsNothing);
      final without = tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground)).contentBottom;

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(hints, findsOneWidget);
      expect(fadeOf(tester, hints).opacity, 1);
      expect(
        tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground)).contentBottom,
        greaterThan(without),
      );

      lb.poke();
      await tester.pumpAndSettle();
      expect(hints, findsNothing);
      lb.end();
    });

    testWidgets('the progress line is 3*scale on an onSurface track and follows the clip', (tester) async {
      const scale = 0.85;
      await playing(tester, size: const Size(960, 540));
      engine.durationCtl.add(const Duration(seconds: 100));
      engine.positionCtl.add(const Duration(seconds: 25));
      await tester.pump();

      final bar = tester.widget<MediaProgressBar>(find.byType(MediaProgressBar));
      expect(bar.minHeight, closeTo(3 * scale, 1e-9));
      final onSurface = Theme.of(tester.element(find.byType(MediaProgressBar))).colorScheme.onSurface;
      expect(bar.backgroundColor, onSurface.withValues(alpha: 0.12));
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.25, 1e-9));
      final rect = tester.getRect(find.byType(MediaProgressBar));
      expect(rect.bottom, closeTo(540 - 10 * scale, 0.5));
      expect(rect.top, greaterThanOrEqualTo(tester.getRect(extras('1')).bottom));
      expect(fadeOf(tester, find.byType(MediaProgressBar)).opacity, 1);

      // It stays while the card is quiet.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(lb.quiet, isTrue);
      expect(fadeOf(tester, find.byType(MediaProgressBar)).opacity, 1);
      lb.end();
    });

    testWidgets('a pause shows the centre disc and a Paused chip inside the overscan margin', (tester) async {
      const size = Size(960, 540);
      await playing(tester, size: size);
      expect(find.text('Paused'), findsNothing);

      await tester.runAsync(c.clips.pause);
      lb.playing = false;
      lb.pulse(paused: true);
      await tester.pump();
      await tester.pump(ForkMotion.sheetIn);
      final disc = tester.widget<TransportFeedbackIndicator>(find.byType(TransportFeedbackIndicator));
      expect(disc.text, 'Paused');
      expect(disc.pulse, 1);
      final chip = find.byKey(const ValueKey('reel-paused'));
      expect(chip, findsOneWidget);
      expect(find.descendant(of: chip, matching: find.text('Paused')), findsOneWidget);
      final rect = tester.getRect(chip);
      expect(rect.left, closeTo(size.width * ReelDeckStrip.overscan, 0.5));
      expect(rect.top, closeTo(size.height * ReelDeckStrip.overscan, 0.5));

      await tester.runAsync(c.clips.resume);
      lb.playing = true;
      lb.pulse(paused: false);
      await tester.pumpAndSettle();
      expect(chip, findsNothing);
      expect(tester.widget<TransportFeedbackIndicator>(find.byType(TransportFeedbackIndicator)).text, 'Playing');
      lb.end();
    });
  });

  group('TV remote (V2-50)', () {
    late ForkDatabase db;
    late ReelController c;
    late FakeClipEngine engine;

    setUp(() async {
      db = ForkDatabase.memory();
      c = _controller(db, _Deck(['1', '2']), (e) => engine = e);
    });

    tearDown(() async {
      c.dispose();
      await db.close();
    });

    String? hintLine(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('reel-hints'))).data;

    Future<void> playing(WidgetTester tester, {ReelOkAction okAction = ReelOkAction.watch}) async {
      // The app's own theme: the sheet's tiles read its tokens.
      await _pumpTv(tester, c, okAction: okAction, theme: monoTheme(MonoPalette.dark));
      engine.firstFrameCtl.add(null);
      await tester.pumpAndSettle();
    }

    /// Opens the sheet over the card, returns which of [labels] it showed,
    /// and closes it again.
    Future<Set<String>> sheetShows(
      WidgetTester tester,
      List<String> labels, {
      required bool isTv,
      ReelOkAction okAction = ReelOkAction.watch,
    }) async {
      final context = tester.element(find.byType(ReelCardView));
      unawaited(showReelSheet(context, c, isTv: isTv, okAction: okAction));
      await tester.pumpAndSettle();
      final shown = {
        for (final l in labels)
          if (find.text(l).evaluate().isNotEmpty) l,
      };
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      return shown;
    }

    testWidgets('the hint line follows the OK pref', (tester) async {
      await playing(tester);
      expect(hintLine(tester), startsWith('OK watch'));

      await playing(tester, okAction: ReelOkAction.details);
      expect(hintLine(tester), startsWith('OK details'));
      expect(find.textContaining('OK watch'), findsNothing);
    });

    testWidgets('a held clip still reads OK replay whatever the pref', (tester) async {
      await playing(tester, okAction: ReelOkAction.details);
      for (var i = 0; i < 4 && c.clips.phase.value != ClipPhase.held; i++) {
        engine.completedCtl.add(true);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(hintLine(tester), startsWith('OK replay'));
    });

    testWidgets("the TV sheet offers Sound off, then Sound on once it's muted", (tester) async {
      await playing(tester);
      const sound = ['Sound off', 'Sound on'];
      expect(await sheetShows(tester, sound, isTv: true), {'Sound off'});

      await tester.runAsync(() => c.setMuted(true));
      expect(c.clips.muted, isTrue);
      expect(await sheetShows(tester, sound, isTv: true), {'Sound on'});
    });

    testWidgets('picking Sound off gives the sound action back', (tester) async {
      await playing(tester);
      final context = tester.element(find.byType(ReelCardView));
      final picked = showReelSheet(context, c, isTv: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sound off'));
      await tester.pumpAndSettle();
      expect(await picked, ReelSheetAction.sound);
    });

    testWidgets('with OK on Details, the TV sheet offers Watch instead of Details', (tester) async {
      await playing(tester, okAction: ReelOkAction.details);
      const both = ['Watch', 'Details'];
      expect(await sheetShows(tester, both, isTv: true, okAction: ReelOkAction.details), {'Watch'});
      expect(await sheetShows(tester, both, isTv: true), {'Details'});
    });

    testWidgets('the phone sheet has no sound item: its mute button is on the card', (tester) async {
      await playing(tester);
      expect(await sheetShows(tester, ['Sound off', 'Sound on', 'Save for the TV'], isTv: false), {'Save for the TV'});
    });
  });
}
