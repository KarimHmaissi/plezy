import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/models/trakt/trakt_user_list.dart';
import 'package:plezy/services/catalog/home_pins.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/trackers/trakt/trakt_client.dart';

import '../../test_helpers/prefs.dart';

/// Trakt with the "Plezy" list earlier versions saved Home rows to.
class _FakeTrakt implements TraktClient {
  _FakeTrakt(this.description);

  final String? description;
  int writes = 0;

  @override
  Future<List<TraktUserList>> getMyLists() async => [
    if (description != null)
      TraktUserList(traktId: 1, slug: HomePinsController.listSlug, name: 'Plezy', description: description),
  ];

  @override
  Future<void> updateMyListDescription(int listId, String newDescription) async => writes++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HomeRowEntry _row(String id) => (id: id, title: id, sources: const <String>[]);

List<String> _ids(HomeLayout layout) => [for (final r in layout.rows) r.id];

void main() {
  late ForkDatabase db;
  late CustomisationStore store;

  setUp(() {
    resetSharedPreferencesForTest();
    db = ForkDatabase.memory();
    store = LocalCustomisationStore(db);
  });
  tearDown(() => db.close());

  HomePinsController controller() => HomePinsController(store: Future.value(store));

  test('rows are saved locally, in order, and read back after a restart', () async {
    final pins = controller();
    await pins.ensureLoaded();
    await Future.wait([
      pins.add([_row('a')]),
      pins.add([_row('b')]),
      pins.add([_row('c')]),
    ]);
    await pins.move('c', -2);
    await pins.setCurated(false);

    final restarted = controller();
    await restarted.ensureLoaded();
    expect(_ids(restarted.layout), ['cw', 'pb', 'c', 'a', 'b']);
    expect(restarted.curated, isFalse);
  });

  test('first run brings rows over from the earlier local copy', () async {
    resetSharedPreferencesForTest(
      initialAsync: {
        'home_layout_cache_v2':
            '{"v":2,"c":1,"r":[["cw","Continue Watching"],["cath:plex:home.top_watchlisted","Most Watchlisted This Week"]]}',
      },
    );
    final pins = controller();
    await pins.ensureLoaded();
    expect(_ids(pins.layout), ['cw', 'cath:plex:home.top_watchlisted']);
    expect((await store.readHomeLayout())!.rows.map((r) => r.id), ['cw', 'cath:plex:home.top_watchlisted']);
  });

  test('first run brings rows over from the Trakt list, read only', () async {
    final trakt = _FakeTrakt(
      writeHomeLayout('My notes', (rows: [_row('cw'), _row('tl:chart:boxoffice')], curated: true), revision: 4),
    );
    final pins = controller()..attachTrakt(trakt);
    await pins.ensureLoaded();
    expect(_ids(pins.layout), ['cw', 'tl:chart:boxoffice']);
    expect(trakt.writes, 0);

    await pins.add([_row('x')]);
    expect(trakt.writes, 0, reason: 'Trakt is no longer written');
  });

  test('rows already in the database are never replaced by the Trakt copy', () async {
    final pins = controller();
    await pins.ensureLoaded();
    await pins.add([_row('mine')]);

    final restarted = controller()
      ..attachTrakt(_FakeTrakt(writeHomeLayout(null, (rows: [_row('old')], curated: true))));
    await restarted.ensureLoaded();
    expect(_ids(restarted.layout), ['cw', 'pb', 'mine']);
  });

  test('with nothing to bring over, Home starts with Continue Watching and Pick back up', () async {
    final pins = controller();
    await pins.ensureLoaded();
    expect(_ids(pins.layout), ['cw', 'pb']);
    expect(pins.curated, isTrue);
  });
}
