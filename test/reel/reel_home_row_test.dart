import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/catalog/home_pins.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/reel_home_row.dart';
import 'package:plezy/services/reel/reel_store.dart';

import '../test_helpers/prefs.dart';

/// One device: its own fork database, Home layout and Reel store.
class _Device {
  _Device(DateTime Function() clock) : db = ForkDatabase.memory() {
    store = LocalCustomisationStore(db);
    pins = HomePinsController(store: Future.value(store));
    reel = ReelStore(database: () async => db, settings: () async => store, clock: clock);
  }

  final ForkDatabase db;
  late final LocalCustomisationStore store;
  late final HomePinsController pins;
  late final ReelStore reel;

  Future<bool> seat({required bool onTv}) => ReelHomeRow.seat(onTv: onTv, store: store, pins: pins, reel: reel);

  /// Catch-up from [other]: everything it has that is newer than here.
  Future<Set<String>> catchUpFrom(_Device other) async {
    final theirs = await other.store.readSyncStamps();
    return store.applySyncUnits(await other.store.readSyncUnits(theirs.keys));
  }

  Future<List<String>> homeIds() async {
    await pins.ensureLoaded(refresh: true);
    return [for (final r in pins.rows) r.id];
  }
}

void main() {
  late DateTime now;
  late _Device tv;
  late _Device phone;

  setUp(() {
    resetSharedPreferencesForTest();
    now = DateTime.utc(2026, 11, 6, 20, 15);
    tv = _Device(() => now);
    phone = _Device(() => now);
  });

  tearDown(() async {
    await tv.db.close();
    await phone.db.close();
  });

  ReelPick pick(String id) => ReelPick(
    titleId: id,
    groupKey: 'g$id',
    serverId: 'server-a',
    ratingKey: 'rk$id',
    title: 'Harbor Lights',
    at: now.subtract(const Duration(hours: 1)),
  );

  test('a phone Save writes the pick only: no Home layout, no home stamp', () async {
    await phone.reel.savePick(pick('a'));
    expect(await phone.seat(onTv: false), isFalse);

    final stamps = await phone.store.readSyncStamps();
    expect(stamps.keys, isNot(contains(SyncUnits.home)));
    expect(stamps.keys, contains(SyncUnits.setting(ReelStore.picksKey)));
    expect(await phone.store.readHomeLayout(), isNull);
    expect(await phone.store.readSetting(ReelHomeRow.seatedKey), isNull);
  });

  test('a synced picks write seats the row on the TV, and the phone never replaces its Home', () async {
    await tv.pins.ensureLoaded();
    await tv.pins.add([(id: 'tl:chart', title: 'Chart', sources: const <String>[])]);
    final tvHomeBefore = await tv.homeIds();

    await phone.reel.savePick(pick('a'));
    await phone.seat(onTv: false);
    final taken = await tv.catchUpFrom(phone);
    expect(taken, {SyncUnits.setting(ReelStore.picksKey)});

    // What Home does on Customisation.changed on the TV.
    expect(await tv.seat(onTv: true), isTrue);
    expect(await tv.homeIds(), [HomeRowIds.reelPicks, ...tvHomeBefore]);
    expect(await ReelHomeRow.freshKey(reel: tv.reel), 'a@${pick('a').at.millisecondsSinceEpoch}');
  });

  test('the TV seats the row once; removing it in Manage Home sticks', () async {
    await tv.reel.savePick(pick('a'));
    expect(await tv.seat(onTv: true), isTrue);
    expect((await tv.homeIds()).first, HomeRowIds.reelPicks);

    await tv.pins.remove([HomeRowIds.reelPicks]);
    await tv.reel.savePick(pick('b'));
    expect(await tv.seat(onTv: true), isFalse);
    expect(await tv.homeIds(), isNot(contains(HomeRowIds.reelPicks)));
  });

  test('no fresh pick, no row', () async {
    expect(await tv.seat(onTv: true), isFalse);
    expect(await tv.homeIds(), isNot(contains(HomeRowIds.reelPicks)));
    expect(await tv.store.readSetting(ReelHomeRow.seatedKey), isNull);
  });

  test('the seated flag stays on its device', () async {
    await tv.reel.savePick(pick('a'));
    await tv.seat(onTv: true);
    expect(SyncUnits.syncsSetting(ReelHomeRow.seatedKey), isFalse);
    expect(SyncUnits.syncsSetting(ReelHomeRow.recheckedKey), isFalse);
    expect((await tv.store.readSyncStamps()).keys, isNot(contains(SyncUnits.setting(ReelHomeRow.seatedKey))));
    final taken = await phone.catchUpFrom(tv);
    expect(taken, isNot(contains(SyncUnits.setting(ReelHomeRow.seatedKey))));
    expect(await phone.store.readSetting(ReelHomeRow.seatedKey), isNull);
  });

  test('a seated flag a phone synced over earlier is re-checked once on the TV', () async {
    // Written before the flag was device-local: set, but the row never seated here.
    await tv.store.writeSetting(ReelHomeRow.seatedKey, '1');
    await phone.reel.savePick(pick('a'));
    await tv.catchUpFrom(phone);

    expect(await tv.seat(onTv: true), isTrue);
    expect((await tv.homeIds()).first, HomeRowIds.reelPicks);
    expect(await tv.store.readSetting(ReelHomeRow.recheckedKey), '1');

    // Only once: a later removal sticks.
    await tv.pins.remove([HomeRowIds.reelPicks]);
    expect(await tv.seat(onTv: true), isFalse);
    expect(await tv.homeIds(), isNot(contains(HomeRowIds.reelPicks)));
  });

  test('calls made together seat the row once', () async {
    await tv.reel.savePick(pick('a'));
    final results = await Future.wait([tv.seat(onTv: true), tv.seat(onTv: true), tv.seat(onTv: true)]);
    expect(results.where((added) => added), hasLength(1));
    expect((await tv.homeIds()).where((id) => id == HomeRowIds.reelPicks), hasLength(1));
  });
}
