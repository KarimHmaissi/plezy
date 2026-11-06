import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/customisation/mirror_store.dart';
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

  group('daily sweep', () {
    Future<Set<String>> keys() async => {for (final r in await db.select(db.reelCache).get()) r.key};

    test('drops pools past the 3 days read, stale deck and cursor rows, expired sources and old events', () async {
      // Written over the past days, each on its own day.
      for (var back = 0; back < 5; back++) {
        final then = now.subtract(Duration(days: back));
        final at = ReelStore(database: () async => db, clock: () => then);
        await at.cache('pool:${ReelStore.dayStamp(then)}', '[]');
        await at.cache('deck:for-you:${ReelStore.dayStamp(then)}', '[]');
        await at.cache('cursor:ai:a1:${ReelStore.dayStamp(then)}', '4');
      }
      final old = ReelStore(database: () async => db, clock: () => now.subtract(const Duration(days: 31)));
      await old.cache('src:g-old', '{"miss":true}');
      await old.record('t-old', ReelAction.sampled);
      await ReelStore(
        database: () async => db,
        clock: () => now.subtract(const Duration(days: 401)),
      ).record('t-ancient', ReelAction.sampled);
      await store.cache('src:g-new', '{"k":"plex:1"}');
      await store.cache('other', 'kept');

      final swept = await store.sweep();

      expect(swept, (pools: 2, days: 2, sources: 1, events: 1));
      expect(await keys(), {
        for (var back = 0; back < 3; back++) ...[
          'pool:${ReelStore.dayStamp(now.subtract(Duration(days: back)))}',
          'deck:for-you:${ReelStore.dayStamp(now.subtract(Duration(days: back)))}',
          'cursor:ai:a1:${ReelStore.dayStamp(now.subtract(Duration(days: back)))}',
        ],
        // Written exactly 3 days ago: not yet older than that.
        'deck:for-you:${ReelStore.dayStamp(now.subtract(const Duration(days: 3)))}',
        'cursor:ai:a1:${ReelStore.dayStamp(now.subtract(const Duration(days: 3)))}',
        'src:g-new',
        'other',
        ReelStore.sweptKey,
      });
      expect((await store.events(since: DateTime.utc(2000))).map((e) => e.titleId), ['t-old']);
    });

    test('runs once a day; calls made together share one run', () async {
      final first = store.sweep();
      final again = store.sweep();
      expect(identical(first, again), isTrue);
      expect(await first, isNotNull);
      expect(await store.sweep(), isNull);
      now = now.add(const Duration(days: 1));
      await store.cache('pool:2026-11-01', '[]');
      expect((await store.sweep())?.pools, 1);
    });
  });

  test('picks and vetoes sync one title at a time; the migration markers stay here', () async {
    await store.savePick(pick('a', now));
    await store.spoiled('x', 'plex:1');
    final stamps = await LocalCustomisationStore(db).readSyncStamps();
    expect(
      stamps.keys,
      containsAll([SyncUnits.setting(ReelStore.pickKey('a')), SyncUnits.setting(ReelStore.vetoKey('x'))]),
    );
    expect(stamps.keys, isNot(contains(SyncUnits.setting(ReelStore.picksKey))));
    expect(stamps.keys, isNot(contains(SyncUnits.setting(ReelStore.vetoesKey))));
    // The old keys still sync for one release, so an older device's copy arrives.
    expect(SyncUnits.syncsSetting(ReelStore.picksKey), isTrue);
    expect(SyncUnits.syncsSetting(ReelStore.vetoesKey), isTrue);
    expect(SyncUnits.syncsSetting(ReelStore.picksMigratedKey), isFalse);
    expect(SyncUnits.syncsSetting(ReelStore.vetoesMigratedKey), isFalse);
  });

  test('removing a pick removes only that title', () async {
    await store.savePick(pick('a', now));
    await store.savePick(pick('b', now));
    await store.removePick('a');
    expect((await store.picks()).map((p) => p.titleId), ['b']);
    expect(await LocalCustomisationStore(db).readSetting(ReelStore.pickKey('a')), isNull);
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

  group('two devices (catch-up)', () {
    late ForkDatabase phoneDb;
    late LocalCustomisationStore tvSettings;
    late LocalCustomisationStore phoneSettings;
    late ReelStore phone;

    setUp(() {
      tvSettings = LocalCustomisationStore(db);
      phoneDb = ForkDatabase.memory();
      phoneSettings = LocalCustomisationStore(phoneDb);
      phone = ReelStore(database: () async => phoneDb, settings: () async => phoneSettings, clock: () => now);
    });

    tearDown(() => phoneDb.close());

    Future<Set<String>> catchUp(LocalCustomisationStore from, LocalCustomisationStore to) async =>
        to.applySyncUnits(await from.readSyncUnits((await from.readSyncStamps()).keys));

    test('Spoiled me bans and Not for me from both devices all survive', () async {
      await store.spoiled('x', 'plex:1');
      await store.notForMe('m');
      now = now.add(const Duration(minutes: 5));
      await phone.spoiled('y', 'plex:2');
      await phone.markFact('k', 'kids');

      await catchUp(phoneSettings, tvSettings);
      await catchUp(tvSettings, phoneSettings);

      for (final s in [store, phone]) {
        expect(await s.spoiledAssets('x'), {'plex:1'});
        expect(await s.spoiledAssets('y'), {'plex:2'});
        expect(await s.excluded(), {'m', 'k'});
      }
    });

    test('picks saved on both devices all reach both; a removal travels too', () async {
      await store.savePick(pick('a', now));
      now = now.add(const Duration(minutes: 1));
      await phone.savePick(pick('b', now));
      await catchUp(phoneSettings, tvSettings);
      await catchUp(tvSettings, phoneSettings);
      expect((await store.freshPicks()).map((p) => p.titleId), ['b', 'a']);
      expect((await phone.freshPicks()).map((p) => p.titleId), ['b', 'a']);

      now = now.add(const Duration(minutes: 1));
      await phone.removePick('a');
      await catchUp(phoneSettings, tvSettings);
      expect((await store.picks()).map((p) => p.titleId), ['b']);
    });

    test('the same title edited on both: the newer edit of that title wins', () async {
      await store.notForMe('x');
      now = now.add(const Duration(minutes: 1));
      await phone.markFact('x', 'seen');
      await catchUp(phoneSettings, tvSettings);
      expect(jsonDecode((await tvSettings.readSetting(ReelStore.vetoKey('x')))!), {'k': 'seen'});
    });
  });

  group('the old one-setting format', () {
    late LocalCustomisationStore settings;

    setUp(() => settings = LocalCustomisationStore(db));

    String oldPicks(List<ReelPick> picks) => jsonEncode([for (final p in picks) p.toJson()]);

    test('is moved into per-title keys once, and read from them after', () async {
      await settings.writeSetting(
        ReelStore.picksKey,
        oldPicks([
          pick('a', now.subtract(const Duration(hours: 2))),
          pick('old', now.subtract(const Duration(days: 4))),
        ]),
      );
      await settings.writeSetting(
        ReelStore.vetoesKey,
        jsonEncode({
          'x': {
            's': ['plex:1'],
          },
          'y': {'k': 'seen'},
          'z': {'n': now.millisecondsSinceEpoch},
        }),
      );

      expect((await store.freshPicks()).map((p) => p.titleId), ['a']);
      expect(await store.excluded(), {'y', 'z'});
      expect(await store.spoiledAssets('x'), {'plex:1'});

      expect(await settings.readSetting(ReelStore.pickKey('a')), isNotNull);
      expect(await settings.readSetting(ReelStore.pickKey('old')), isNull, reason: 'stale picks are not moved');
      expect(await settings.readSetting(ReelStore.vetoKey('x')), isNotNull);
      expect(await settings.readSetting(ReelStore.picksMigratedKey), isNotNull);
      expect(await settings.readSetting(ReelStore.vetoesMigratedKey), isNotNull);
      // The old keys are left for an older device still reading them.
      expect(await settings.readSetting(ReelStore.picksKey), isNotNull);
    });

    test('a pick removed after the move does not come back from the old key', () async {
      await settings.writeSetting(ReelStore.picksKey, oldPicks([pick('a', now), pick('b', now)]));
      expect(await store.picks(), hasLength(2));
      await store.removePick('a');
      expect((await store.picks()).map((p) => p.titleId), ['b']);
      // A fresh store (an app restart) reads the same.
      final again = ReelStore(database: () async => db, settings: () async => settings, clock: () => now);
      expect((await again.picks()).map((p) => p.titleId), ['b']);
    });

    test('removing a pick before anything was read still sticks', () async {
      await settings.writeSetting(ReelStore.picksKey, oldPicks([pick('a', now)]));
      await store.removePick('a');
      expect(await store.picks(), isEmpty);
    });

    test('a newer copy from an older device is moved again and merged per title', () async {
      await store.spoiled('x', 'plex:1');
      await store.savePick(pick('a', now.subtract(const Duration(hours: 1))));
      // An older device writes its whole set (it never saw the per-title keys).
      await settings.writeSetting(
        ReelStore.vetoesKey,
        jsonEncode({
          'x': {
            's': ['plex:9'],
          },
        }),
      );
      await settings.writeSetting(ReelStore.picksKey, oldPicks([pick('a', now.subtract(const Duration(hours: 3)))]));

      expect(await store.spoiledAssets('x'), {'plex:1', 'plex:9'});
      expect((await store.picks()).single.at, now.subtract(const Duration(hours: 1)), reason: 'the newer save wins');
    });

    test('reads made together move it once', () async {
      await settings.writeSetting(ReelStore.picksKey, oldPicks([pick('a', now)]));
      final writesBefore = Customisation.localWrites.value;
      final all = await Future.wait([store.picks(), store.picks(), store.freshPicks()]);
      expect(all.map((l) => l.single.titleId), ['a', 'a', 'a']);
      // One pick key and one marker.
      expect(Customisation.localWrites.value - writesBefore, 2);
    });

    test('a phone mirroring a TV that has not moved it yet reads it as it is, writing nothing', () async {
      final sent = <Map<String, Object?>>[];
      final mirror = MirrorCustomisationStore(
        {
          'settings': {
            ReelStore.picksKey: oldPicks([pick('a', now)]),
            ReelStore.vetoesKey: jsonEncode({
              'x': {
                's': ['plex:1'],
              },
              'y': {'k': 'kids'},
            }),
          },
        },
        send: (op) {
          sent.add(op);
          return true;
        },
      );
      final phone = ReelStore(database: () async => db, settings: () async => mirror, clock: () => now);
      expect((await phone.freshPicks()).map((p) => p.titleId), ['a']);
      expect(await phone.excluded(), {'y'});
      expect(await phone.spoiledAssets('x'), {'plex:1'});
      expect(sent, isEmpty);

      // An edit keeps what the TV's old copy had for that title.
      await phone.spoiled('x', 'plex:2');
      expect(sent.single['key'], ReelStore.vetoKey('x'));
      expect(await phone.spoiledAssets('x'), {'plex:1', 'plex:2'});
    });
  });
}
