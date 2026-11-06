import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/reel_signals.dart';
import 'package:plezy/services/reel/reel_store.dart';

void main() {
  late ForkDatabase tvDb, phoneDb;
  late LocalCustomisationStore synced;
  late ReelStore tv, phone;
  late DateTime now;

  setUp(() {
    tvDb = ForkDatabase.memory();
    phoneDb = ForkDatabase.memory();
    // One synced settings store stands in for the data both devices share;
    // events stay in each device's own database.
    synced = LocalCustomisationStore(tvDb);
    now = DateTime(2026, 3, 10, 20);
    tv = ReelStore(database: () async => tvDb, settings: () async => synced, clock: () => now);
    phone = ReelStore(database: () async => phoneDb, settings: () async => synced, clock: () => now);
  });

  tearDown(() async {
    await tvDb.close();
    await phoneDb.close();
  });

  Future<void> recordAt(ReelStore store, DateTime at, String id, ReelAction action) async {
    final was = now;
    now = at;
    await store.record(id, action, deck: 'for-you');
    now = was;
  }

  ReelSignals signalsOf(ReelStore store, {required bool host}) =>
      ReelSignals(store: store, host: host, clock: () => now);

  test("each device shares a per-day aggregate under its own key, and reads the other's", () async {
    await recordAt(phone, DateTime(2026, 3, 9, 21), 'm:harbor', ReelAction.toEnd);
    await recordAt(phone, DateTime(2026, 3, 9, 21, 5), 'm:harbor', ReelAction.toEnd);
    await recordAt(phone, DateTime(2026, 3, 10, 9), 'm:harbor', ReelAction.details);
    await recordAt(phone, DateTime(2026, 3, 10, 9, 5), 'm:lantern', ReelAction.unplayed);
    await recordAt(tv, DateTime(2026, 3, 10, 19), 's:orchard', ReelAction.quickSkip);

    await signalsOf(phone, host: false).publish();
    await signalsOf(tv, host: true).publish();

    final shared = jsonDecode((await synced.readSetting(ReelSignals.phoneKey))!) as Map;
    expect(shared['days'], {
      '2026-03-09': {'m:harbor': 'ee'},
      '2026-03-10': {'m:harbor': 'd'},
    }, reason: 'unplayed is neutral and never shared');
    expect(SyncUnits.syncsSetting(ReelSignals.phoneKey), isTrue);
    expect(SyncUnits.syncsSetting(ReelSignals.hostKey), isTrue);

    final onTv = await signalsOf(tv, host: true).since(DateTime(2026, 2, 8));
    expect(onTv.where((s) => s.titleId == 's:orchard').single.action, ReelAction.quickSkip);
    final fromPhone = onTv.where((s) => s.titleId == 'm:harbor').toList();
    expect(ReelSignals.count(fromPhone, ReelAction.toEnd), 2);
    expect(ReelSignals.count(fromPhone, ReelAction.details), 1);
    expect(fromPhone.first.at.hour, 12, reason: "the other device's events are timed at their day's noon");

    final onPhone = await signalsOf(phone, host: false).since(DateTime(2026, 2, 8));
    expect(onPhone.map((s) => s.titleId).toSet(), {'m:harbor', 's:orchard'});
  });

  test('publishing again with nothing new does not write', () async {
    await recordAt(phone, DateTime(2026, 3, 10, 9), 'm:harbor', ReelAction.save);
    final signals = signalsOf(phone, host: false);
    await signals.publish();
    final writes = Customisation.localWrites.value;
    await signals.publish();
    expect(Customisation.localWrites.value, writes);
    await recordAt(phone, DateTime(2026, 3, 10, 10), 'm:harbor', ReelAction.watch);
    await signals.publish();
    expect(Customisation.localWrites.value, greaterThan(writes));
  });

  test('the shared aggregate keeps 30 days, and a phone that cannot write keeps going', () async {
    await recordAt(phone, DateTime(2026, 2, 8, 12), 'm:old', ReelAction.sampled);
    await recordAt(phone, DateTime(2026, 2, 9, 12), 'm:kept', ReelAction.sampled);
    await signalsOf(phone, host: false).publish();
    final days = (jsonDecode((await synced.readSetting(ReelSignals.phoneKey))!) as Map)['days'] as Map;
    expect(days.keys, ['2026-02-09']);

    final readOnly = ReelStore(
      database: () async => phoneDb,
      settings: () async => throw StateError('not connected'),
      clock: () => now,
    );
    await signalsOf(readOnly, host: false).publish();
    expect(await signalsOf(readOnly, host: false).since(DateTime(2026, 2, 1)), isNotEmpty);
  });

  test('decoding skips old days, unknown codes and junk', () {
    final raw = jsonEncode({
      'v': 1,
      'days': {
        '2026-03-01': {'m:a': 'e'},
        '2026-03-09': {'m:b': 'eZn', 'm:c': 7},
        'not a day': {'m:d': 'e'},
      },
    });
    final got = ReelSignals.decode(raw, since: DateTime(2026, 3, 5, 18));
    expect(got.map((s) => (s.titleId, s.action, s.n)), [('m:b', ReelAction.toEnd, 1), ('m:b', ReelAction.notForMe, 1)]);
    expect(ReelSignals.decode('not json', since: DateTime(2026)), isEmpty);
    expect(ReelSignals.decode(null, since: DateTime(2026)), isEmpty);
  });

  test("quick skips from the other device add to this device's fatigue", () async {
    await recordAt(tv, DateTime(2026, 3, 10, 18), 'm:harbor', ReelAction.quickSkip);
    await recordAt(phone, DateTime(2026, 3, 9, 8), 'm:harbor', ReelAction.quickSkip);
    await recordAt(phone, DateTime(2026, 3, 9, 9), 'm:harbor', ReelAction.quickSkip);
    await signalsOf(phone, host: false).publish();
    final skips = await signalsOf(tv, host: true).quickSkips();
    expect(skips['m:harbor'], hasLength(3));
  });

  test('per-candidate facts name saves not played yet, clips to the end, Details, replays and unmutes', () {
    DateTime d(int day, [int hour = 12]) => DateTime(2026, 3, day, hour);
    final signals = <ReelSignal>[
      (titleId: 'a', action: ReelAction.save, at: d(8), n: 1),
      (titleId: 'a', action: ReelAction.toEnd, at: d(8), n: 2),
      (titleId: 'b', action: ReelAction.save, at: d(9), n: 1),
      (titleId: 'b', action: ReelAction.watch, at: d(9, 21), n: 1),
      (titleId: 'c', action: ReelAction.details, at: d(10), n: 1),
      (titleId: 'c', action: ReelAction.replay, at: d(10), n: 3),
      (titleId: 'c', action: ReelAction.unmute, at: d(10), n: 1),
      (titleId: 'z', action: ReelAction.toEnd, at: d(10), n: 1),
    ];
    final notes = ReelSignals.notes(
      signals,
      {'a', 'b', 'c', 'd', 'e'},
      picks: {'e': DateTime.utc(2026, 3, 9, 20)},
      now: DateTime(2026, 3, 10, 20),
    );
    expect(notes['a'], ['saved 2 days ago, not played yet', 'clip watched to the end 2×']);
    expect(notes.containsKey('b'), isFalse, reason: 'played after the save');
    expect(notes['c'], ['opened Details', 'replayed 3×', 'unmuted']);
    expect(notes.containsKey('d'), isFalse);
    expect(notes['e']?.single, startsWith('saved '));
    expect(notes.containsKey('z'), isFalse, reason: 'not a candidate');
  });

  test('counts include Not for me, and per-kind lines join on the pool clusters, busiest first', () {
    final at = DateTime(2026, 3, 10, 12);
    final signals = <ReelSignal>[
      (titleId: 'a', action: ReelAction.sampled, at: at, n: 2),
      (titleId: 'a', action: ReelAction.notForMe, at: at, n: 1),
      (titleId: 'b', action: ReelAction.quickSkip, at: at, n: 1),
      (titleId: 'c', action: ReelAction.toEnd, at: at, n: 3),
      (titleId: 'x', action: ReelAction.save, at: at, n: 1),
    ];
    expect(
      ReelSignals.countsLine(signals),
      '2 sampled, 3 watched to the end, 1 skipped within 2 s, 1 Not for me, 1 saved',
    );
    expect(ReelSignals.clusterLines(signals, {'a': 'harbor drama', 'b': 'harbor drama', 'c': 'cosy anime'}), [
      '- harbor drama: 2 sampled, 1 skipped within 2 s, 1 Not for me',
      '- cosy anime: 3 watched to the end',
    ]);
  });
}
