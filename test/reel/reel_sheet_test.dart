import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_item.dart';
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
import 'package:plezy/theme/mono_theme.dart';

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
  Future<MediaItem?> item(String serverId, String ratingKey) async => null;

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) => item(serverId, ratingKey);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

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

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
  });

  tearDown(() async => db.close());

  // Built outside the widget test's fake zone (the resolver's queue lives in
  // the zone it was made in), as the feed test builds its controller in setUp.
  ReelController make({ReelMoreLike? moreLike}) => ReelController(
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
    onWatch: (_, {required onTv}) async => false,
    addToWatchlist: (_) async => true,
    externalClips: true,
    moreLike: moreLike,
  );

  Future<ReelSheetAction?> open(WidgetTester tester, ReelController c, {String? pick}) async {
    ReelSheetAction? picked;
    await tester.runAsync(c.start);
    await tester.pumpWidget(
      MaterialApp(
        // The desktop popup: the same entries as the phone and TV sheet.
        theme: monoTheme(MonoPalette.dark).copyWith(platform: TargetPlatform.linux),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => picked = await showReelSheet(context, c, isTv: false),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    if (pick != null) {
      await tester.tap(find.text(pick));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }
    return picked;
  }

  testWidgets('the sheet offers More like this straight after Save', (tester) async {
    final c = (await tester.runAsync(() async => make(moreLike: (seed, {required skip}) async => null)))!;
    addTearDown(c.dispose);
    await open(tester, c);
    expect(find.text('More like this'), findsOneWidget);
    final save = tester.getTopLeft(find.text('Save for the TV')).dy;
    expect(tester.getTopLeft(find.text('More like this')).dy, greaterThan(save));
    expect(
      tester.getTopLeft(find.text('Not for me')).dy,
      greaterThan(tester.getTopLeft(find.text('More like this')).dy),
    );
  });

  testWidgets('picking More like this returns its action', (tester) async {
    final c = (await tester.runAsync(() async => make(moreLike: (seed, {required skip}) async => null)))!;
    addTearDown(c.dispose);
    expect(await open(tester, c, pick: 'More like this'), ReelSheetAction.moreLike);
  });

  testWidgets('without a finder the sheet leaves it out', (tester) async {
    final c = (await tester.runAsync(() async => make()))!;
    addTearDown(c.dispose);
    await open(tester, c);
    expect(find.text('Save for the TV'), findsOneWidget);
    expect(find.text('More like this'), findsNothing);
  });

  testWidgets('a saved card offers Remove from saved, below Save; an unsaved one does not', (tester) async {
    final c = (await tester.runAsync(() async => make()))!;
    addTearDown(c.dispose);
    await open(tester, c);
    expect(find.text('Remove from saved'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pump(const Duration(milliseconds: 600));

    await tester.runAsync(() => c.save(silent: true));
    expect(await open(tester, c, pick: 'Remove from saved'), ReelSheetAction.unsave);
    await open(tester, c);
    expect(
      tester.getTopLeft(find.text('Remove from saved')).dy,
      greaterThan(tester.getTopLeft(find.text('Save for the TV')).dy),
      reason: 'the focused first entry stays Save, so a quick OK never removes it',
    );
  });
}
