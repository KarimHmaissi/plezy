import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/ai_history.dart';
import 'package:plezy/services/companion_remote/catch_up_sync.dart';
import 'package:plezy/services/customisation/customisation_store.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/prefs.dart';

AiHistoryEntry _entry(String id, DateTime createdAt) {
  final item = testMediaItem(id: 'rk-$id', title: 'Film $id', serverId: 's1', year: 2020);
  return AiHistoryEntry(
    id: id,
    request: 'request $id',
    intro: 'Intro $id',
    createdAt: createdAt,
    items: [item],
    reasons: const {},
  );
}

/// One catch-up round between [phone] and [tv], as the protocol runs it:
/// the TV answers the phone's offer, the phone takes the TV's newer pieces
/// and pushes what the TV asked for. Returns the pieces moved each way.
Future<({int toPhone, int toTv})> _round(LocalCustomisationStore phone, LocalCustomisationStore tv) async {
  final offer = CatchUp.decodeStamps(CatchUp.encodeStamps(await phone.readSyncStamps()));
  final tvStamps = await tv.readSyncStamps();
  final reply = await tv.readSyncUnits(CatchUp.newerHere(tvStamps, offer));
  final want = CatchUp.newerHere(offer, tvStamps);

  Customisation.debugSetStore(phone);
  final toPhone = await CatchUp.take(reply);
  final push = await phone.readSyncUnits(want);
  Customisation.debugSetStore(tv);
  final toTv = await CatchUp.take(push);
  return (toPhone: toPhone, toTv: toTv);
}

void main() {
  late ForkDatabase phoneDb;
  late ForkDatabase tvDb;
  late LocalCustomisationStore phone;
  late LocalCustomisationStore tv;

  setUp(() {
    resetSharedPreferencesForTest();
    phoneDb = ForkDatabase.memory();
    tvDb = ForkDatabase.memory();
    phone = LocalCustomisationStore(phoneDb);
    tv = LocalCustomisationStore(tvDb);
  });
  tearDown(() async {
    Customisation.debugSetStore(null);
    await phoneDb.close();
    await tvDb.close();
  });

  test('writes are stamped; device-only settings are not', () async {
    await phone.writeSetting('watchlist.source', 'trakt');
    await phone.writeSetting('ai.spend.2026-11', '{"usd":1}');
    await phone.writeSetting('comfort.shows', '[]');
    await phone.writeComfortPaused({2: 'Frasier'});
    await phone.writeHomeLayout(const [], curated: true, revision: 3);

    final stamps = await phone.readSyncStamps();
    expect(stamps.keys, unorderedEquals(['setting:watchlist.source', SyncUnits.comfort, SyncUnits.home]));
  });

  test('the newer edit of a piece wins, in both directions', () async {
    await tv.writeSetting('watchlist.source', 'plex');
    await tv.writeComfortPaused({1: 'Friends'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await phone.writeSetting('watchlist.source', 'trakt');
    await phone.writeSetting('ai.suggestions', '["phone list"]');

    final moved = await _round(phone, tv);

    expect(moved, (toPhone: 1, toTv: 2));
    expect(await tv.readSetting('watchlist.source'), 'trakt');
    expect(await tv.readSetting('ai.suggestions'), '["phone list"]');
    expect(await phone.readComfortPaused(), {1: 'Friends'});
    // Both sides now agree, so a second round moves nothing.
    expect(await _round(phone, tv), (toPhone: 0, toTv: 0));
  });

  test('a removal reaches the other device', () async {
    await tv.writeSetting('ai.week.dismissed', '2026-11-02');
    await _round(phone, tv);
    expect(await phone.readSetting('ai.week.dismissed'), '2026-11-02');

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await phone.writeSetting('ai.week.dismissed', null);
    await _round(phone, tv);

    expect(await tv.readSetting('ai.week.dismissed'), isNull);
  });

  test('AI answers from both devices end up on both, newest first', () async {
    Customisation.debugSetStore(tv);
    await AiHistory.add(_entry('tvOld', DateTime(2026, 11, 1)));
    Customisation.debugSetStore(phone);
    await AiHistory.add(_entry('phoneNew', DateTime(2026, 11, 3)));
    await AiHistory.add(_entry('phoneMid', DateTime(2026, 11, 2)));

    await _round(phone, tv);

    for (final device in [phone, tv]) {
      Customisation.debugSetStore(device);
      expect([for (final e in await AiHistory.page(limit: 10)) e.id], ['phoneNew', 'phoneMid', 'tvOld']);
    }

    // Deleting an answer on the TV deletes it on the phone too.
    Customisation.debugSetStore(tv);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await AiHistory.remove('phoneMid');
    await _round(phone, tv);
    Customisation.debugSetStore(phone);
    expect([for (final e in await AiHistory.page(limit: 10)) e.id], ['phoneNew', 'tvOld']);
  });

  test('a Home layout moves whole and keeps its stamp', () async {
    await phone.writeHomeLayout(
      [(id: 'cw', title: 'Continue Watching', sources: const <String>[])],
      curated: true,
      revision: 4,
    );
    final units = await phone.readSyncUnits([SyncUnits.home]);

    expect(await tv.applySyncUnits(units), {SyncUnits.home});
    final home = await tv.readHomeLayout();
    expect(home?.rows.single.id, 'cw');
    expect(home?.revision, 4);
    expect((await tv.readSyncStamps())[SyncUnits.home], (await phone.readSyncStamps())[SyncUnits.home]);
    // The same copy again is not newer, so it is not taken twice.
    expect(await tv.applySyncUnits(units), isEmpty);
  });
}
