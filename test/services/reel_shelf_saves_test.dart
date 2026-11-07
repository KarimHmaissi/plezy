import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel_shelf_saves.dart';
import 'package:plezy/services/system_shelf_service.dart' show SystemShelf;
import 'package:plezy/services/reel/reel_store.dart';

import '../test_helpers/media_items.dart';

class _Client implements MediaServerClient {
  final List<String> reads = [];
  final Set<String> failing = {};
  final Set<String> slow = {};
  final Set<String> missing = {};

  @override
  Future<MediaItem?> fetchItem(String id) async {
    reads.add(id);
    if (failing.contains(id)) throw StateError('server unavailable');
    if (slow.contains(id)) return Completer<MediaItem?>().future;
    if (id == 'gone' || missing.contains(id)) return null;
    return testMediaItem(id: id, kind: MediaKind.show, title: 'Title $id', serverId: 'server-a');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final savedAt = DateTime.utc(2026, 11, 6, 20, 15);

  ReelPick pick(String ratingKey, {String serverId = 'server-a', DateTime? at}) => ReelPick(
    titleId: 't-$ratingKey',
    groupKey: 'g-$ratingKey',
    serverId: serverId,
    ratingKey: ratingKey,
    title: 'Harbor Lights',
    at: at ?? savedAt,
  );

  test('each Save is read once, then kept until the Save changes', () async {
    final client = _Client();
    var picks = [pick('rk1'), pick('rk2')];
    final saves = ReelShelfSaves(picks: () async => picks);
    MediaServerClient? clientFor(ServerId id) => id.value == 'server-a' ? client : null;

    final first = await saves.load(clientFor);
    expect(first.map((s) => (s.item.id, s.savedAt)), [('rk1', savedAt), ('rk2', savedAt)]);
    expect(client.reads, ['rk1', 'rk2']);

    await saves.load(clientFor);
    expect(client.reads, ['rk1', 'rk2'], reason: 'a second sync reads nothing');

    // rk1 saved again (new time): read again. rk2 unsaved: dropped.
    final later = savedAt.add(const Duration(hours: 1));
    picks = [pick('rk1', at: later)];
    final third = await saves.load(clientFor);
    expect(third.map((s) => (s.item.id, s.savedAt)), [('rk1', later)]);
    expect(client.reads, ['rk1', 'rk2', 'rk1']);
  });

  test('more Saves than Play Next can take: only the newest ${SystemShelf.maxItems} are read', () async {
    final client = _Client();
    final picks = [for (var i = 0; i < 30; i++) pick('rk$i', at: savedAt.subtract(Duration(minutes: i)))];
    final saves = ReelShelfSaves(picks: () async => picks);
    MediaServerClient? clientFor(ServerId id) => id.value == 'server-a' ? client : null;

    final loaded = await saves.load(clientFor);
    expect(loaded.map((s) => s.item.id), [for (var i = 0; i < SystemShelf.maxItems; i++) 'rk$i']);
    expect(client.reads, hasLength(SystemShelf.maxItems));
  });

  test('an unreachable, failing, slow or missing Save is left out and asked about again', () async {
    final client = _Client()
      ..failing.add('rk-fail')
      ..slow.add('rk-slow');
    final saves = ReelShelfSaves(
      picks: () async => [pick('rk-ok'), pick('rk-fail'), pick('rk-slow'), pick('gone'), pick('rk-x', serverId: 'b')],
      fetchTimeout: const Duration(milliseconds: 10),
    );
    MediaServerClient? clientFor(ServerId id) => id.value == 'server-a' ? client : null;

    expect((await saves.load(clientFor)).map((s) => s.item.id), ['rk-ok']);
    client.failing.clear();
    expect((await saves.load(clientFor)).map((s) => s.item.id), ['rk-ok', 'rk-fail']);
    expect(client.reads.where((id) => id == 'rk-ok'), hasLength(1));
    expect(client.reads.where((id) => id == 'rk-slow'), hasLength(2));
    expect(client.reads.where((id) => id == 'gone'), hasLength(2));
  });

  test('Saves that can no longer be read give their Play Next slots to older ones', () async {
    final client = _Client()..missing.addAll({'rk0', 'rk1', 'rk2'});
    final picks = [for (var i = 0; i < 30; i++) pick('rk$i', at: savedAt.subtract(Duration(minutes: i)))];
    final saves = ReelShelfSaves(picks: () async => picks);
    MediaServerClient? clientFor(ServerId id) => id.value == 'server-a' ? client : null;

    final loaded = await saves.load(clientFor);
    expect(loaded.map((s) => s.item.id), [for (var i = 3; i < SystemShelf.maxItems + 3; i++) 'rk$i']);
    expect(client.reads, hasLength(SystemShelf.maxItems + 3), reason: 'only as many more as were short');
  });

  test('it looks only so far: at most ${ReelShelfSaves.lookAhead} Saves are read', () async {
    final client = _Client();
    final picks = [for (var i = 0; i < 60; i++) pick('rk$i', at: savedAt.subtract(Duration(minutes: i)))];
    client.missing.addAll(picks.map((p) => p.ratingKey));
    final saves = ReelShelfSaves(picks: () async => picks);
    MediaServerClient? clientFor(ServerId id) => id.value == 'server-a' ? client : null;

    expect(await saves.load(clientFor), isEmpty);
    expect(client.reads, [for (var i = 0; i < ReelShelfSaves.lookAhead; i++) 'rk$i']);
  });

  group('from the saved list itself', () {
    late ForkDatabase db;

    setUp(() {
      db = ForkDatabase.memory();
      Customisation.debugSetLocalDatabase(db);
      Customisation.debugSetStore(LocalCustomisationStore(db));
    });

    tearDown(() async {
      Customisation.debugSetStore(null);
      Customisation.debugSetLocalDatabase(null);
      await db.close();
    });

    test('every Save, old ones too, newest first (no cap of ${ReelPick.maxShown}, no 3-day expiry)', () async {
      final now = DateTime.now().toUtc();
      final ages = [
        const Duration(minutes: 5),
        const Duration(hours: 2),
        const Duration(days: 1),
        const Duration(days: 5),
        const Duration(days: 40),
      ];
      for (var i = 0; i < ages.length; i++) {
        await ReelStore.instance.savePick(pick('rk$i', at: now.subtract(ages[i])));
      }
      final client = _Client();

      final loaded = await ReelShelfSaves().load((id) => id.value == 'server-a' ? client : null);
      expect(loaded.map((s) => s.item.id), ['rk0', 'rk1', 'rk2', 'rk3', 'rk4']);
    });
  });
}
