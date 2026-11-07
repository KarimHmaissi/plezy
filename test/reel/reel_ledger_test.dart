import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/reel_ledger.dart';
import 'package:plezy/services/reel/reel_signals.dart';
import 'package:plezy/services/reel/reel_store.dart';

/// V2-44: the pick ledger over the Reel's events and vetoes (invented ids).
void main() {
  late ForkDatabase tvDb, phoneDb;
  late LocalCustomisationStore synced;
  late ReelStore tv, phone;
  late DateTime now;

  setUp(() {
    tvDb = ForkDatabase.memory();
    phoneDb = ForkDatabase.memory();
    synced = LocalCustomisationStore(tvDb);
    now = DateTime(2026, 3, 10, 20);
    tv = ReelStore(database: () async => tvDb, settings: () async => synced, clock: () => now);
    phone = ReelStore(database: () async => phoneDb, settings: () async => synced, clock: () => now);
  });

  tearDown(() async {
    await tvDb.close();
    await phoneDb.close();
  });

  DateTime daysAgo(int days, {int hour = 20, int minute = 0}) =>
      DateTime(now.year, now.month, now.day - days, hour, minute);

  Future<void> at(DateTime when, Future<void> Function() write) async {
    final was = now;
    now = when;
    await write();
    now = was;
  }

  Future<void> recordAt(ReelStore store, DateTime when, String id, ReelAction action) =>
      at(when, () => store.record(id, action, deck: 'for-you'));

  ReelLedger ledgerOf(ReelStore store, {bool host = true, Duration cacheFor = Duration.zero}) =>
      ReelLedger(store: store, host: () => host, clock: () => now, cacheFor: cacheFor);

  test('a showing is 8 s of a clip or an action; one visit counts once; quick skips never count', () async {
    await recordAt(tv, daysAgo(3), 'm:harbor', ReelAction.sampled);
    await recordAt(tv, daysAgo(3, minute: 5), 'm:harbor', ReelAction.save);
    await recordAt(tv, daysAgo(1), 'm:harbor', ReelAction.toEnd);
    await recordAt(tv, daysAgo(0, hour: 9), 'm:harbor', ReelAction.quickSkip);
    await recordAt(tv, daysAgo(0, hour: 9), 'm:copper', ReelAction.quickSkip);
    await recordAt(tv, daysAgo(0, hour: 9), 'm:lantern', ReelAction.unplayed);

    final all = await ledgerOf(tv).snapshot();
    expect(all.keys, ['m:harbor'], reason: 'a quick skip or a card left unplayed is not a showing');
    final s = all['m:harbor']!;
    expect(s.timesShown, 2, reason: 'the sample and the Save in one visit are one showing');
    expect(s.lastShown, daysAgo(1));
    expect(s.surfaces, {PickSurface.reel});
    expect(s.outcome, PickOutcome.pending);
    expect(s.shownWeight, greaterThan(0.8));
    expect(s.shownWeight, lessThan(1.0), reason: 'each Reel showing weighs 0.5 and halves every 21 days');
    expect(s.factLine(), 'shown 2× in the Reel lately, not played yet');
  });

  test('showings older than 60 days say nothing', () async {
    await recordAt(tv, daysAgo(70), 'm:harbor', ReelAction.sampled);
    await recordAt(tv, daysAgo(10), 'm:harbor', ReelAction.sampled);
    await recordAt(tv, daysAgo(65), 'm:orchard', ReelAction.toEnd);

    final all = await ledgerOf(tv).snapshot();
    expect(all.keys, ['m:harbor']);
    expect(all['m:harbor']!.timesShown, 1);
  });

  test('a Reel Watch after a showing took: no fact is said', () async {
    await recordAt(tv, daysAgo(5), 'm:harbor', ReelAction.sampled);
    await recordAt(tv, daysAgo(2), 'm:harbor', ReelAction.watch);
    await recordAt(tv, daysAgo(4), 's:salt', ReelAction.details);
    await recordAt(tv, daysAgo(4, minute: 1), 's:salt', ReelAction.watchOnTv);

    final all = await ledgerOf(tv).snapshot();
    expect(all['m:harbor']!.outcome, PickOutcome.took);
    expect(all['s:salt']!.outcome, PickOutcome.took);
    expect(all['m:harbor']!.factLine(), isNull);
    expect(all['s:salt']!.factLine(), isNull);
  });

  test("the other device's shared days count, one showing a day", () async {
    await recordAt(phone, daysAgo(2, hour: 21), 'm:harbor', ReelAction.sampled);
    await recordAt(phone, daysAgo(2, hour: 23), 'm:harbor', ReelAction.toEnd);
    await recordAt(phone, daysAgo(2, hour: 22), 'm:copper', ReelAction.save);
    await ReelSignals(store: phone, host: false, clock: () => now).publish();
    await recordAt(tv, daysAgo(1), 'm:harbor', ReelAction.sampled);

    final onTv = await ledgerOf(tv).snapshot();
    expect(onTv['m:harbor']!.timesShown, 2, reason: "the phone's day, then the TV's own showing");
    expect(onTv['m:copper']!.timesShown, 1);

    final onPhone = await ledgerOf(phone, host: false).snapshot();
    expect(onPhone['m:harbor']!.timesShown, 2, reason: "the phone's own two visits; the TV hasn't shared its day yet");
  });

  test('Not for me: rests 90 days, said as "passed on" until 180, then gone', () async {
    await at(daysAgo(20), () => tv.notForMe('m:harbor'));
    await at(daysAgo(120), () => tv.notForMe('m:copper'));
    await at(daysAgo(200), () => tv.notForMe('m:orchard'));

    final ledger = ledgerOf(tv);
    final all = await ledger.snapshot();
    expect(all.keys.toSet(), {'m:harbor', 'm:copper'});
    expect(all['m:harbor']!.timesShown, 0);
    expect(all['m:harbor']!.factLine(), 'passed on in ${SeenState.monthName(daysAgo(20).month)}');
    expect(all['m:copper']!.factLine(), startsWith('passed on in '));
    expect(await ledger.resting(), {'m:harbor'});
  });

  test('summaries, shownWithin and promptFacts', () async {
    await recordAt(tv, daysAgo(2), 'm:harbor', ReelAction.sampled);
    await recordAt(tv, daysAgo(12), 'm:copper', ReelAction.sampled);
    await recordAt(tv, daysAgo(1), 'm:lantern', ReelAction.quickSkip);
    final ledger = ledgerOf(tv);

    final some = await ledger.summaries(['m:harbor', 'm:unknown']);
    expect(some.keys, ['m:harbor']);
    expect(await ledger.shownWithin(const Duration(days: 5)), {'m:harbor'});
    expect(await ledger.shownWithin(const Duration(days: 30)), {'m:harbor', 'm:copper'});
    expect(await ledger.shownWithin(const Duration(days: 5), surfaces: const [PickSurface.ask]), isEmpty);
    expect(await ledger.promptFacts(), 'Reel, last 30 days: 2 sampled, 1 skipped within 2 s');
    expect(await ledgerOf(phone, host: false).promptFacts(), '');
  });

  test('the ledger never records: the Reel writes its own events', () async {
    final ledger = ledgerOf(tv);
    await ledger.record([PickEvent(id: 'm:harbor', surface: PickSurface.ask, action: PickAction.shown, at: now)]);
    expect(await tv.events(since: daysAgo(400)), isEmpty);
  });

  test('one read is reused for a minute, then read again', () async {
    final ledger = ledgerOf(tv, cacheFor: const Duration(minutes: 1));
    await recordAt(tv, daysAgo(2), 'm:harbor', ReelAction.sampled);
    expect((await ledger.snapshot()).keys, ['m:harbor']);

    await recordAt(tv, daysAgo(1), 'm:copper', ReelAction.sampled);
    expect((await ledger.snapshot()).keys, ['m:harbor'], reason: 'the same burst reuses the read');

    now = now.add(const Duration(minutes: 2));
    expect((await ledger.snapshot()).keys.toSet(), {'m:harbor', 'm:copper'});

    await recordAt(tv, daysAgo(1), 'm:orchard', ReelAction.sampled);
    ledger.forget();
    expect((await ledger.snapshot()).keys.toSet(), {'m:harbor', 'm:copper', 'm:orchard'});
  });
}
