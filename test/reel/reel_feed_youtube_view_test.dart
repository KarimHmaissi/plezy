import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/reel/reel_feed_view.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/feed_players.dart';
import 'package:plezy/services/reel/feed_youtube.dart';
import 'package:plezy/services/reel/reel_art.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/reel/reel_tmdb.dart';

import 'clip_player_test.dart' show FakeClipEngine;

/// A YouTube trailer card in the phone feed (V2-63): nothing over the
/// player, the sound control outside it, and the player never under 200 dp.

class _Servers implements ReelServers {
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => const [];

  @override
  String? clipUrl(String serverId, String partKey) => 'https://cdn.example$partKey';
}

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async => MediaItem(
    id: ratingKey,
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Harbor Lights $ratingKey',
    year: 2020,
  );

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) => item(serverId, ratingKey);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

class _Deck extends ReelDeck {
  @override
  String get id => 'a';
  @override
  String get name => 'Deck A';
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;

  @override
  Future<List<ReelCardData>> load() async => [_card('1'), _card('2')];
}

ReelCardData _card(String id) => ReelCardData(
  title: ReelTitle(
    titleId: 't$id',
    groupKey: 'g$id',
    title: 'Harbor Lights $id',
    isShow: false,
    tmdbId: 100 + int.parse(id),
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
    title: 'Harbor Lights $id',
    genres: '',
    countries: '',
    directors: '',
    writers: '',
    cast: '',
    collections: '',
    groupKey: 'g$id',
    summary: 'A keeper relights the harbor lamp.',
  ),
  why: 'Like the films you finish.',
);

/// The player page, drawn as a keyed box.
class _Embed extends ChangeNotifier implements EmbedFeedVideo {
  _Embed({this.upOnPlay = true});

  /// Whether a play puts its picture up at once.
  final bool upOnPlay;
  bool _ready = false;
  bool up = false;
  bool _playing = false;
  final volumes = <double>[];

  @override
  bool get ready => _ready;
  @override
  bool get failed => false;
  @override
  bool get pictureUp => up;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => const Duration(seconds: 90);
  @override
  bool get playing => _playing;
  @override
  bool get buffering => false;
  @override
  bool get completed => false;
  @override
  Duration get buffered => Duration.zero;
  @override
  Future<void> initialize() async => _ready = true;
  @override
  Future<void> play() async {
    _playing = true;
    up = upOnPlay;
    notifyListeners();
  }

  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setLooping(bool looping) async {}
  @override
  Future<void> dispose() async => super.dispose();
  @override
  Widget view() => const ColoredBox(key: ValueKey('yt-player'), color: Colors.red);
}

void main() {
  late ForkDatabase db;
  late ReelController c;
  late ReelFeedPlayers players;
  late Map<String, _Embed> pages;
  var upOnPlay = true;

  setUp(() {
    ReelArt.resetForTesting();
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    final store = ReelStore(database: () async => db, settings: () async => settings);
    c = ReelController(
      decks: [_Deck()],
      resolver: ClipResolver(
        servers: _Servers(),
        store: store,
        aniList: (_) async => null,
        animeThemes: (_) async => const {},
        tmdb: ReelTmdbRung(
          fetch: ({required id, required show, required language}) async => [
            {'key': 'Trailer$id', 'site': 'YouTube', 'type': 'Trailer', 'official': true, 'iso_639_1': 'en'},
          ],
          on: () => true,
          language: () => 'en',
        ),
      ),
      clips: ClipPlayer(engine: FakeClipEngine.new),
      store: store,
      media: _Media(),
      onWatch: (_, {required onTv}) async => true,
      addToWatchlist: (_) async => true,
      externalClips: true,
      saveMuted: (_) async {},
    );
    c.stuckAfter = null;
    pages = {};
    upOnPlay = true;
    players = ReelFeedPlayers(
      create: (uri) => pages[ReelYouTube.idOf(uri)!] = _Embed(upOnPlay: upOnPlay),
      riseOver: Duration.zero,
      stuckAfter: null,
    );
  });

  tearDown(() async {
    c.dispose();
    players.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, {Size size = const Size(420, 860)}) async {
    tester.view.physicalSize = size;
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
            onWatch: () {},
            onSheet: () {},
            onDecks: () {},
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the trailer plays in the player page, credited, with the info below it and clear of the top bar', (
    tester,
  ) async {
    await pump(tester);
    expect(c.current.clip?.source.origin, ClipOrigin.youtube);
    final player = find.byKey(const ValueKey('yt-player'));
    expect(player, findsOneWidget);
    expect(find.text('Trailer via YouTube'), findsOneWidget);
    final rect = tester.getRect(player);
    final title = tester.getRect(find.text('Harbor Lights 1').first);
    expect(rect.bottom, lessThanOrEqualTo(title.top), reason: 'the info sits below the player, never over it');
    // The top bar and its scrim end 72 dp down (no status bar here).
    expect(rect.top, greaterThanOrEqualTo(72));
  });

  testWidgets('it starts silent: the sound control (outside the player) shows sound off, and a tap gives it sound', (
    tester,
  ) async {
    await pump(tester);
    final page = pages.values.single;
    expect(players.muted, isFalse);
    expect(find.byTooltip('Sound on'), findsOneWidget);
    expect(page.volumes.where((v) => v > 0), isEmpty);

    final control = tester.getRect(find.byTooltip('Sound on'));
    expect(control.overlaps(tester.getRect(find.byKey(const ValueKey('yt-player')))), isFalse);

    await tester.tap(find.byTooltip('Sound on'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(players.quiet, isFalse);
    expect(page.volumes.last, 1.0);
    expect(find.byTooltip('Mute'), findsOneWidget);
  });

  testWidgets('a tap pauses it with nothing drawn over the player', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('yt-player')), warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    expect(players.paused, isTrue);
    // The pause mark over the picture (the Watch button has the same icon).
    final pauseMark = find.byWidgetPredicate((w) => w is Icon && w.icon == Symbols.play_arrow_rounded && w.size == 44);
    expect(pauseMark, findsOneWidget);
    final overlay = tester.widget<AnimatedOpacity>(
      find.ancestor(of: pauseMark, matching: find.byType(AnimatedOpacity)).first,
    );
    expect(overlay.opacity, 0, reason: 'a native clip shows the pause mark over its picture; a YouTube player never');
  });

  testWidgets('the page is drawn once loaded, before its video plays, with the art behind it until then', (
    tester,
  ) async {
    upOnPlay = false;
    await pump(tester);
    final page = pages.values.single;
    double opacityAbove(Finder f) =>
        tester.widget<AnimatedOpacity>(find.ancestor(of: f, matching: find.byType(AnimatedOpacity)).first).opacity;
    final player = find.byKey(const ValueKey('yt-player'));
    final art = find.descendant(
      of: find.byKey(ValueKey(('reel-still-art', c.current.card!.id))),
      matching: find.byType(AnimatedOpacity),
    );
    expect(opacityAbove(player), 1, reason: 'the player is on screen before it is asked to play (RMF)');
    expect(tester.widget<AnimatedOpacity>(art.first).opacity, 1, reason: 'the art stays up behind the page');

    page
      ..up = true
      ..notifyListeners();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<AnimatedOpacity>(art.first).opacity, 0, reason: 'the art goes once the video plays');
  });

  testWidgets('on a narrow screen the player is never under 200 dp tall', (tester) async {
    await pump(tester, size: const Size(320, 860));
    final rect = tester.getRect(find.byKey(const ValueKey('yt-player')));
    expect(rect.height, greaterThanOrEqualTo(ReelYouTube.minSide));
    expect(rect.width, lessThanOrEqualTo(320));
  });

  test('the frame is narrowed only below the minimum height', () {
    expect(reelMinHeightAspect(16 / 9, 420, 200), 16 / 9);
    expect(reelMinHeightAspect(16 / 9, 320, 200), 320 / 200);
    expect(reelMinHeightAspect(16 / 9, 320, 0), 16 / 9);
  });
}
