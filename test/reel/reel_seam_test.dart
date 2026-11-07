// The fake engine's controllers are closed with the player.
// ignore_for_file: close_sinks

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/reel_app.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';
import 'clip_player_test.dart' show FakeClipEngine;

/// The only calls a Reel session may make on a Plex server (spec §8): a
/// title's extras, a clip part's URL and a card's metadata (the lean Reel
/// read, plan V2-03, or the full item). Anything else (a timeline, a
/// scrobble, a rating) would report watch state.
const _allowed = {#fetchExtraClips, #clipUrl, #fetchReelMetadataJson, #fetchItem};

/// A Plex server that records every call made on it. Calls outside the
/// three the Reel may make are recorded and then fail.
class _RecordingPlex implements PlexClient {
  final calls = <Symbol>[];

  @override
  Future<List<PlexExtraClip>> fetchExtraClips(
    String ratingKey, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(#fetchExtraClips);
    return [
      PlexExtraClip(
        ratingKey: 'x$ratingKey',
        title: 'Trailer',
        partKey: '/services/iva/assets/$ratingKey/video.mp4',
        subtype: 'trailer',
      ),
    ];
  }

  @override
  String clipUrl(String partKey) {
    calls.add(#clipUrl);
    return 'https://server-a.example$partKey';
  }

  /// The server's identity, not a call to it.
  @override
  String get scopedServerId => 's1';

  @override
  Future<Map<String, dynamic>?> fetchReelMetadataJson(
    String ratingKey, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    calls.add(#fetchReelMetadataJson);
    return {'ratingKey': ratingKey, 'type': 'movie', 'title': 'Title $ratingKey'};
  }

  @override
  Future<MediaItem?> fetchItem(String id) async {
    calls.add(#fetchItem);
    return MediaItem(id: id, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Title $id', serverId: 's1');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    return super.noSuchMethod(invocation);
  }
}

/// The app's servers, with [plex] as the one connected server.
class _Servers implements MultiServerManager {
  _Servers(this.plex);

  final _RecordingPlex plex;

  @override
  MediaServerClient? getClient(ServerId serverId) => serverId == 's1' ? plex : null;

  @override
  bool isServerOnline(ServerId serverId) => serverId == 's1';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Deck extends ReelDeck {
  _Deck(this.id, this.cards);

  @override
  final String id;
  final List<ReelCardData> cards;
  @override
  String get name => 'Deck $id';
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;
  @override
  Future<List<ReelCardData>> load() async => cards;
}

ReelCardData _card(String id, String title) => ReelCardData(
  title: ReelTitle(
    titleId: 't$id',
    groupKey: 'g$id',
    title: title,
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
    title: title,
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

/// V2-62: a Reel session over the app's own server seams (the Plex extras
/// door and the card metadata reader) touches the server only through
/// extras, clipUrl and fetchItem, whatever the viewer does.
void main() {
  late ForkDatabase db;
  late ReelStore store;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    db = ForkDatabase.memory();
    // The app's metadata cache, empty: each card is read from the server.
    final appDb = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(appDb);
    addTearDown(appDb.close);
    final custom = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => custom);
  });

  tearDown(() => db.close());

  test('a whole session calls only extras, clipUrl and the card reads on the server', () async {
    final plex = _RecordingPlex();
    final servers = _Servers(plex);
    final c = ReelController(
      decks: [
        _Deck('a', [_card('1', 'Harbor Lights'), _card('2', 'Lantern Bay'), _card('3', 'Quiet Orchard')]),
        _Deck('b', [_card('4', 'Salt Road'), _card('5', 'Copper Hill')]),
      ],
      resolver: ReelApp.resolverFor(servers, store),
      clips: ClipPlayer(engine: FakeClipEngine.new),
      store: store,
      media: ReelApp.mediaFor(servers, store),
      // Watch and the watchlist are the app's real plays; not the Reel's.
      onWatch: (_, {required onTv}) async => true,
      addToWatchlist: (_) async => true,
    );

    await c.start();
    await c.step(1);
    await c.save();
    await c.step(1);
    await c.spoiledMe();
    await c.seenIt();
    await c.notForMe();
    await c.switchDeck(1);
    await c.step(1);
    await c.step(-1);
    await c.togglePause();
    await c.replay();
    await c.suspend();
    await c.start();
    await c.suspend();

    expect(plex.calls, containsAll({#fetchExtraClips, #clipUrl}), reason: 'the session resolved clips');
    expect(plex.calls.toSet().intersection({#fetchReelMetadataJson, #fetchItem}), isNotEmpty, reason: 'and read cards');
    final others = plex.calls.toSet().difference(_allowed);
    expect(others, isEmpty, reason: 'only extras, clipUrl and the card reads reach the server');
  });

  test('the recorder sees a call outside the allowed ones', () {
    final plex = _RecordingPlex();
    expect(() => plex.markAsWatched('1'), throwsNoSuchMethodError);
    expect(plex.calls, [#markAsWatched]);
  });
}
