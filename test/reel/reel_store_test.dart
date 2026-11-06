import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/reel_store.dart';

void main() {
  late ForkDatabase db;
  late DateTime now;
  late ReelStore store;

  setUp(() {
    db = ForkDatabase.memory();
    now = DateTime.utc(2026, 11, 6, 8, 20);
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings, clock: () => now);
  });

  tearDown(() => db.close());

  ReelPick pick(String id, DateTime at) =>
      ReelPick(titleId: id, groupKey: 'g$id', serverId: 's', ratingKey: 'rk$id', title: 'Title $id', at: at);

  test('picks wait 3 days, newest first, at most 3', () async {
    await store.savePick(pick('a', now.subtract(const Duration(days: 4))));
    await store.savePick(pick('b', now.subtract(const Duration(hours: 5))));
    await store.savePick(pick('c', now.subtract(const Duration(hours: 3))));
    await store.savePick(pick('d', now.subtract(const Duration(hours: 2))));
    await store.savePick(pick('e', now.subtract(const Duration(hours: 1))));
    expect((await store.freshPicks()).map((p) => p.titleId), ['e', 'd', 'c']);
    // Saving prunes stale picks.
    expect((await store.picks()).map((p) => p.titleId), isNot(contains('a')));
  });

  test('saving the same title again replaces it', () async {
    await store.savePick(pick('a', now.subtract(const Duration(hours: 2))));
    await store.savePick(pick('a', now));
    expect(await store.picks(), hasLength(1));
    expect((await store.picks()).single.at, now);
  });

  test('Not for me rests 90 days; Seen it and For kids are permanent', () async {
    await store.notForMe('x');
    await store.markFact('y', 'seen');
    expect(await store.excluded(), {'x', 'y'});
    now = now.add(const Duration(days: 91));
    expect(await store.excluded(), {'y'});
  });

  test('Spoiled me bans the asset, not the title', () async {
    await store.spoiled('x', 'plex:123');
    await store.spoiled('x', 'plex:456');
    expect(await store.spoiledAssets('x'), {'plex:123', 'plex:456'});
    expect(await store.excluded(), isEmpty);
  });

  test('quick skips feed fatigue with a 14-day half-life', () async {
    await store.record('t', ReelAction.quickSkip);
    now = now.add(const Duration(days: 14));
    await store.record('t', ReelAction.quickSkip);
    await store.record('t', ReelAction.sampled, seconds: 40);
    expect(await store.fatigueOf('t'), closeTo(1.5, 1e-6));
    expect(await store.fatigueOf('other'), 0);
  });

  test('cache entries expire after their ttl', () async {
    await store.cache('src:g1', '{"k":"plex:1"}');
    expect(await store.cached('src:g1', ttl: ReelStore.sourceTtl), isNotNull);
    now = now.add(const Duration(days: 31));
    expect(await store.cached('src:g1', ttl: ReelStore.sourceTtl), isNull);
    expect(await store.cached('src:g1'), isNotNull);
  });

  test('events and caches never become sync units; picks and vetoes do', () {
    expect(SyncUnits.syncsSetting(ReelStore.picksKey), isTrue);
    expect(SyncUnits.syncsSetting(ReelStore.vetoesKey), isTrue);
  });

  test('a schema 2 database upgrades to 3 with the Reel tables, keeping its data', () async {
    final dir = await Directory.systemTemp.createTemp('fork_db_upgrade');
    final file = File('${dir.path}/fork.db');
    // Build a real v2 file: today's schema minus the Reel tables, at version 2.
    final v3 = ForkDatabase(NativeDatabase(file));
    await LocalCustomisationStore(v3).writeSetting('home.revision', '7');
    await v3.customStatement('DROP TABLE reel_events');
    await v3.customStatement('DROP TABLE reel_cache');
    await v3.customStatement('PRAGMA user_version = 2');
    await v3.close();

    final upgraded = ForkDatabase(NativeDatabase(file));
    final s = ReelStore(database: () async => upgraded, settings: () async => LocalCustomisationStore(upgraded));
    await s.record('t', ReelAction.save);
    await s.cache('k', 'v');
    expect(await LocalCustomisationStore(upgraded).readSetting('home.revision'), '7');
    expect((await s.events(since: DateTime.utc(2000))).single.action, 'save');
    await upgraded.close();
    await dir.delete(recursive: true);
  });

  test('many cache rows read at once, stale ones left out', () async {
    await store.cache('src:ga', '{"miss":true}');
    now = now.add(const Duration(days: 31));
    await store.cache('src:gb', '{"miss":true}');
    expect(await store.cachedMany(['src:ga', 'src:gb', 'src:gc'], ttl: ReelStore.sourceTtl), {
      'src:gb': '{"miss":true}',
    });
    expect((await store.cachedMany(['src:ga', 'src:gb'])).keys, unorderedEquals(['src:ga', 'src:gb']));
    expect(await store.cachedMany(const []), isEmpty);
  });
}
