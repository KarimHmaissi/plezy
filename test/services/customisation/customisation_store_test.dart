import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/models/trakt/trakt_catalog_entry.dart';
import 'package:plezy/models/trakt/trakt_user_list.dart';
import 'package:plezy/services/catalog/trakt_catalog_source.dart';
import 'package:plezy/services/comfort/comfort_list_description.dart';
import 'package:plezy/services/comfort/comfort_shows_controller.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/trackers/trakt/trakt_client.dart';

CatalogItem _show(int id, String title) => CatalogItem(
  source: CatalogSourceId.trakt,
  kind: MediaKind.show,
  ids: CatalogItemIds(trakt: id),
  title: title,
);

/// The Comfort Shows list: Flatmates (1), Quiet Harbour (2), Corner Diner (3); earlier
/// versions recorded Quiet Harbour as paused in its description.
class _FakeComfortTrakt implements TraktClient {
  int descriptionWrites = 0;
  final String description = writePausedTraktIds('My comfort shows', {2: 'Quiet Harbour'});

  @override
  Future<List<TraktUserList>> getMyLists() async => [
    TraktUserList(traktId: 9, slug: ComfortShowsController.listSlug, name: 'Comfort Shows', description: description),
  ];

  @override
  Future<List<TraktCatalogEntry>> getMyListShows(int listId) async => const [];

  @override
  Future<void> updateMyListDescription(int listId, String description) async => descriptionWrites++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTraktSource implements TraktCatalogSource {
  _FakeTraktSource(this.client);

  @override
  final _FakeComfortTrakt client;

  @override
  List<CatalogItem> showsFromListEntries(List<TraktCatalogEntry> entries) => [
    _show(1, 'Flatmates'),
    _show(2, 'Quiet Harbour'),
    _show(3, 'Corner Diner'),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ForkDatabase db;
  late LocalCustomisationStore store;

  setUp(() {
    db = ForkDatabase.memory();
    store = LocalCustomisationStore(db);
  });
  tearDown(() => db.close());

  Future<void> seed(LocalCustomisationStore target) async {
    await target.writeHomeLayout(
      [
        (id: 'cw', title: 'Continue Watching', sources: const <String>[]),
        (id: 'px:hey spooky picks', title: 'Hey, Spooky Picks!', sources: ['srv|/hubs/x']),
        (id: 'tl:chart:boxoffice', title: 'Box Office', sources: const <String>[]),
      ],
      curated: false,
      revision: 7,
    );
    await target.writeComfortPaused({2: 'Quiet Harbour', 3: 'Corner Diner'});
    await target.writeSetting('future.setting', 'on');
  }

  test('export then import into another device restores everything', () async {
    await seed(store);
    final file = CustomisationExport.encode(
      await store.exportAll(),
      appVersion: '1.2.3',
      now: DateTime.utc(2026, 11, 1),
    );

    final otherDb = ForkDatabase.memory();
    addTearDown(otherDb.close);
    final other = LocalCustomisationStore(otherDb);
    await other.writeComfortPaused({99: 'Something else'});

    final data = CustomisationExport.decode(file);
    expect(CustomisationExport.summary(data), (homeRows: 3, comfortPaused: 2, shortlist: 0));
    await other.importAll(data);

    final home = (await other.readHomeLayout())!;
    expect([for (final r in home.rows) r.id], ['cw', 'px:hey spooky picks', 'tl:chart:boxoffice']);
    expect(home.rows[1].sources, ['srv|/hubs/x']);
    expect(home.curated, isFalse);
    expect(await other.readComfortPaused(), {2: 'Quiet Harbour', 3: 'Corner Diner'});
    expect(await other.readSetting('future.setting'), 'on');
  });

  test('files that are not backups, or from a newer version, are rejected clearly', () {
    expect(
      () => CustomisationExport.decode('not json'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', 'notJson')),
    );
    expect(
      () => CustomisationExport.decode('{"hello":1}'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', 'notBackup')),
    );
    expect(
      () => CustomisationExport.decode('{"format":"plezy-fork-backup","schemaVersion":99}'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', 'newerVersion')),
    );
    expect(
      () => CustomisationExport.decode(
        '{"format":"plezy-fork-backup","schemaVersion":1,"homeLayout":{"rows":[{"title":"no id"}]}}',
      ),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', 'notBackup')),
    );
  });

  test('Comfort paused shows come over from the list description once, then live locally', () async {
    final trakt = _FakeComfortTrakt();
    final comfort = ComfortShowsController(_FakeTraktSource(trakt), store: Future.value(store));
    await comfort.load(createIfMissing: false);
    expect([for (final s in comfort.pausedShows) s.title], ['Quiet Harbour']);

    await comfort.setPaused(_show(3, 'Corner Diner'), true);
    expect(await store.readComfortPaused(), {2: 'Quiet Harbour', 3: 'Corner Diner'});
    expect(trakt.descriptionWrites, 0, reason: 'the list description is no longer written');

    // The old description still says only Quiet Harbour; the local record wins.
    final again = ComfortShowsController(_FakeTraktSource(trakt), store: Future.value(store));
    await again.load(createIfMissing: false);
    expect([for (final s in again.pausedShows) s.title], ['Quiet Harbour', 'Corner Diner']);
  });

  test('Comfort without Trakt shows the list the Trakt device last saw, pauses included', () async {
    final trakt = _FakeComfortTrakt();
    await ComfortShowsController(_FakeTraktSource(trakt), store: Future.value(store)).load(createIfMissing: false);

    final cached = ComfortShowsController.cached(store: Future.value(store));
    await cached.load();
    expect(cached.canEditList, isFalse);
    expect(cached.shows, isNotEmpty);
    expect([for (final s in cached.pausedShows) s.title], ['Quiet Harbour']);

    await cached.setPaused(cached.activeShows.first, true);
    expect((await store.readComfortPaused()).length, 2);
  });

  test('a phone adds and removes Comfort shows by sending the edit to its TV', () async {
    final sent = <Map<String, Object?>>[];
    ComfortShowsController.sendMirrorEdit = (op) {
      sent.add(op);
      return true;
    };
    addTearDown(() => ComfortShowsController.sendMirrorEdit = null);
    final cached = ComfortShowsController.cached(store: Future.value(store));
    await cached.load();

    await cached.addShow(_show(7, 'Show A'));
    expect([for (final s in cached.shows) s.title], contains('Show A'));
    await cached.removeShow(_show(7, 'Show A'));
    expect([for (final s in cached.shows) s.title], isNot(contains('Show A')));
    expect(
      [for (final op in sent) (op['op'], op['action'], (op['show'] as Map)['trakt'])],
      [('comfortList', 'add', 7), ('comfortList', 'remove', 7)],
    );

    ComfortShowsController.sendMirrorEdit = (_) => false;
    expect(() => cached.addShow(_show(8, 'Show B')), throwsStateError);
  });

  test('settings read by key prefix: exactly the keys that start with it', () async {
    final db = ForkDatabase.memory();
    addTearDown(db.close);
    final store = LocalCustomisationStore(db);
    await store.writeSetting('reel.pick.a', '1');
    await store.writeSetting('reel.pick.b_2', '2');
    await store.writeSetting('reel.picks', 'old');
    await store.writeSetting('reel.pick', 'bare');
    await store.writeSetting('reel.pick/', 'after');
    await store.writeSetting('reel.veto.a', '3');
    expect(await store.readSettingsWithPrefix('reel.pick.'), {'reel.pick.a': '1', 'reel.pick.b_2': '2'});
    expect(await store.readSettingsWithPrefix('reel.veto.'), {'reel.veto.a': '3'});
    expect(await store.readSettingsWithPrefix('none.'), isEmpty);
  });
}
