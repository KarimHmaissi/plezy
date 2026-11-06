import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/catalog_sources_provider.dart';
import 'package:plezy/services/catalog/home_pins.dart';
import 'package:plezy/services/catalog/home_rows.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/reel_store.dart';

/// A server that has some titles and fails on others.
class _Server implements MediaServerClient {
  _Server(this.server, {this.failing = const {}});

  final String server;
  final Set<String> failing;
  final asked = <String>[];

  @override
  Future<MediaItem?> fetchItem(String id) async {
    asked.add(id);
    if (failing.contains(id)) throw Exception('server error');
    return MediaItem(id: id, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Title $id', serverId: server);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// V2-62: Home's "From the Reel" row shows the fresh Saves, newest first,
/// read from the copy that was saved; a title that can't be read is left
/// out instead of taking the row down.
void main() {
  late ForkDatabase db;
  late CatalogSourcesProvider sources;
  final now = DateTime.now().toUtc();

  setUp(() {
    db = ForkDatabase.memory();
    Customisation.debugSetLocalDatabase(db);
    Customisation.debugSetStore(LocalCustomisationStore(db));
    sources = CatalogSourcesProvider();
  });

  tearDown(() async {
    sources.dispose();
    Customisation.debugSetStore(null);
    Customisation.debugSetLocalDatabase(null);
    await db.close();
  });

  Future<void> save(String id, String serverId, String title, Duration ago) => ReelStore.instance.savePick(
    ReelPick(titleId: 't$id', groupKey: 'g$id', serverId: serverId, ratingKey: id, title: title, at: now.subtract(ago)),
  );

  const row = (id: HomeRowIds.reelPicks, title: 'From the Reel', sources: <String>[]);

  test('fresh Saves, newest first, at most ${ReelPick.maxShown}; stale ones are gone', () async {
    final a = _Server('s1');
    await save('1', 's1', 'Copper Hill', const Duration(hours: 5));
    await save('2', 's1', 'Harbor Lights', const Duration(minutes: 1));
    await save('3', 's1', 'Lantern Bay', const Duration(hours: 1));
    await save('4', 's1', 'Salt Road', const Duration(hours: 9));
    await save('5', 's1', 'Quiet Orchard', const Duration(days: 4));

    final hub = await HomeRowResolver(sources: sources, clientFor: (id) => id == 's1' ? a : null).fetch(row);

    expect(hub?.id, 'home:${HomeRowIds.reelPicks}');
    expect(hub?.items.map((i) => i.id), ['2', '3', '1']);
    expect(a.asked, isNot(contains('5')), reason: 'a Save older than three days is never read');
  });

  test('a title its server fails on, or on a server not connected, is left out', () async {
    final a = _Server('s1', failing: {'2'});
    await save('1', 's1', 'Harbor Lights', const Duration(minutes: 3));
    await save('2', 's1', 'Lantern Bay', const Duration(minutes: 2));
    await save('3', 's2', 'Quiet Orchard', const Duration(minutes: 1));

    final hub = await HomeRowResolver(sources: sources, clientFor: (id) => id == 's1' ? a : null).fetch(row);

    expect(hub?.items.map((i) => i.id), ['1']);
    expect(a.asked, ['2', '1']);
  });

  test('no Saves: an empty row, no server read', () async {
    final a = _Server('s1');
    final hub = await HomeRowResolver(sources: sources, clientFor: (_) => a).fetch(row);
    expect(hub?.items, isEmpty);
    expect(a.asked, isEmpty);
  });
}
