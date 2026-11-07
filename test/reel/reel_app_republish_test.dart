import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/reel_app.dart';

import 'clip_player_test.dart' show FakeClipEngine;

class _Servers implements ReelServers {
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => const [];

  @override
  String? clipUrl(String serverId, String partKey) => null;
}

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async =>
      MediaItem(id: ratingKey, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Harbor Lights');

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) => item(serverId, ratingKey);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

class _Deck extends ReelDeck {
  _Deck(this.id, this.name);

  @override
  final String id;

  @override
  final String name;

  @override
  bool get keepsSeen => true;

  @override
  Future<List<ReelCardData>> load() async => const [];
}

void main() {
  late ForkDatabase db;
  late ReelStore store;

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    ReelApp.debugResetPublishers();
  });

  tearDown(() async {
    ReelApp.debugResetPublishers();
    await db.close();
  });

  /// One session build, on its own deck so the state says which it is.
  ReelController build(String deck) => ReelController(
    decks: [_Deck(deck, 'Deck $deck')],
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
  );

  group('On TV republish after a session build over the limit', () {
    for (final keptFirst in [true, false]) {
      test('the build the screen keeps is resent, the discarded one never '
          '(${keptFirst ? 'kept build finished first' : 'discarded build finished first'})', () {
        final sent = <String>[];
        void send(Map<String, Object?> state) => sent.add(state['deck']! as String);

        final kept = build('kept'), discarded = build('late');
        // Both builds publish as they finish; the late one is let go by the
        // screen ([ReelScreenState] disposes a build it doesn't adopt).
        for (final c in keptFirst ? [kept, discarded] : [discarded, kept]) {
          ReelApp.publishState(c, connected: () => true, send: send);
        }
        discarded.dispose();

        ReelApp.republish();
        expect(sent, ['kept']);

        ReelApp.republish();
        expect(sent, ['kept', 'kept'], reason: 'forced, even with nothing changed');
        kept.dispose();
      });
    }

    test('a disposed session never sends, and republish with none alive sends nothing', () {
      final sent = <String>[];
      final c = build('only');
      ReelApp.publishState(c, connected: () => true, send: (s) => sent.add(s['deck']! as String));
      c.dispose();
      ReelApp.republish();
      expect(sent, isEmpty);
    });

    test('while no phone is connected nothing is sent', () {
      final sent = <String>[];
      var connected = false;
      final c = build('only');
      ReelApp.publishState(c, connected: () => connected, send: (s) => sent.add(s['deck']! as String));
      ReelApp.republish();
      expect(sent, isEmpty);
      connected = true;
      ReelApp.republish();
      expect(sent, ['only']);
      c.dispose();
    });
  });
}
