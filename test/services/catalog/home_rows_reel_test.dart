import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/catalog_sources_provider.dart';
import 'package:plezy/services/catalog/home_pins.dart';
import 'package:plezy/services/catalog/home_rows.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/reel_store.dart';

import '../../test_helpers/media_items.dart';

/// A server whose items arrive at once, except [slow] ones, which never do.
class _Server implements MediaServerClient {
  _Server({this.slow = const {}});

  final Set<String> slow;

  @override
  Future<MediaItem?> fetchItem(String id) =>
      slow.contains(id) ? Completer<MediaItem?>().future : Future.value(testMediaItem(id: id, title: 'Title $id'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaHub _hub(int items) => MediaHub(
  id: 'h',
  title: 'Row',
  type: 'mixed',
  items: [for (var i = 0; i < items; i++) testMediaItem(id: 'i$i')],
);

void main() {
  group('an empty row is an answer, not a failure', () {
    test('fetch states', () {
      expect(homeRowFetchState(null), HomeRowLoadState.unavailable);
      expect(homeRowFetchState(_hub(0)), HomeRowLoadState.empty);
      expect(homeRowFetchState(_hub(2)), HomeRowLoadState.loaded);
    });

    test('an empty row never schedules a retry', () {
      final retries = HomeRowRetries();
      expect(retries.after([HomeRowLoadState.empty]), isNull);
      expect(retries.after([HomeRowLoadState.loaded, HomeRowLoadState.empty]), isNull);
      expect(retries.count, 0);
    });

    test('an empty row does not use up the retries of a row still connecting', () {
      final retries = HomeRowRetries();
      expect(retries.after([HomeRowLoadState.unavailable, HomeRowLoadState.empty]), const Duration(seconds: 10));
      expect(retries.after([HomeRowLoadState.unavailable]), const Duration(seconds: 20));
      // The other row arrived; the empty one is still empty: the count resets.
      expect(retries.after([HomeRowLoadState.loaded, HomeRowLoadState.empty]), isNull);
      expect(retries.count, 0);
      expect(retries.after([HomeRowLoadState.unavailable]), const Duration(seconds: 10));
    });

    test('unavailable rows retry four times, then wait for something else to reload them', () {
      final retries = HomeRowRetries();
      final waits = [
        for (var i = 0; i < 6; i++) retries.after([HomeRowLoadState.unavailable]),
      ];
      expect(waits, [
        const Duration(seconds: 10),
        const Duration(seconds: 20),
        const Duration(seconds: 30),
        const Duration(seconds: 40),
        null,
        null,
      ]);
      retries.reset();
      expect(retries.after([HomeRowLoadState.unavailable]), const Duration(seconds: 10));
    });
  });

  group('the Reel row', () {
    late ForkDatabase db;
    late ReelStore reel;
    late CatalogSourcesProvider sources;
    final now = DateTime.utc(2026, 11, 6, 21);

    setUp(() {
      db = ForkDatabase.memory();
      final store = LocalCustomisationStore(db);
      reel = ReelStore(database: () async => db, settings: () async => store, clock: () => now);
      sources = CatalogSourcesProvider();
    });

    tearDown(() async {
      sources.dispose();
      await db.close();
    });

    Future<void> save(String id, Duration ago) => reel.savePick(
      ReelPick(
        titleId: id,
        groupKey: 'g$id',
        serverId: 'server-a',
        ratingKey: id,
        title: 'Harbor Lights',
        at: now.subtract(ago),
      ),
    );

    test('a slow server times out and the row shows the rest, newest first', () async {
      await save('rk1', const Duration(hours: 3));
      await save('rk2', const Duration(hours: 2));
      await save('rk3', const Duration(hours: 1));
      final resolver = HomeRowResolver(
        sources: sources,
        clientFor: (_) => _Server(slow: {'rk2'}),
        reel: reel,
        pickFetchTimeout: const Duration(milliseconds: 50),
      );

      final hub = await resolver
          .fetch((id: HomeRowIds.reelPicks, title: 'From the Reel', sources: const <String>[]))
          .timeout(const Duration(seconds: 2));
      expect([for (final i in hub!.items) i.id], ['rk3', 'rk1']);
    });

    test('no fresh picks is an empty row', () async {
      await save('rk1', const Duration(days: 4));
      final resolver = HomeRowResolver(sources: sources, clientFor: (_) => _Server(), reel: reel);
      final hub = await resolver.fetch((id: HomeRowIds.reelPicks, title: 'From the Reel', sources: const <String>[]));
      expect(homeRowFetchState(hub), HomeRowLoadState.empty);
    });
  });
}
