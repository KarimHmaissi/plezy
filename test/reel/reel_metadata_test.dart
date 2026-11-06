import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/reel_metadata.dart';
import 'package:plezy/services/reel/reel_store.dart';

/// A server seam with an app cache and a lean read the test controls.
class _Source implements ReelMetadataSource {
  /// The app's cached rows: item and its age.
  final Map<String, ({String title, Duration age})> shared = {};

  /// Lean reads, in the order they started, and the ones still open.
  final List<String> reads = [];
  final Map<String, Completer<Map<String, dynamic>?>> open = {};
  bool gate = false;
  Object? fail;
  bool missing = false;

  @override
  String? scope(String serverId) => serverId == 'gone' ? null : 'scope-$serverId';

  @override
  Future<MediaItem?> cached(String serverId, String ratingKey, {Duration? maxAge}) async {
    final row = shared['$serverId/$ratingKey'];
    if (row == null || (maxAge != null && row.age > maxAge)) return null;
    return _item(serverId, ratingKey, row.title);
  }

  @override
  Future<Map<String, dynamic>?> lean(String serverId, String ratingKey) async {
    final id = '$serverId/$ratingKey';
    reads.add(id);
    if (fail case final e?) throw e;
    if (missing) return null;
    if (gate) return (open[id] = Completer()).future;
    return {'ratingKey': ratingKey, 'title': 'Lean $ratingKey'};
  }

  @override
  MediaItem parse(String serverId, Map<String, dynamic> json) =>
      _item(serverId, json['ratingKey'] as String, json['title'] as String);

  MediaItem _item(String serverId, String id, String title) =>
      MediaItem(id: id, backend: MediaBackend.plex, kind: MediaKind.movie, title: title, serverId: serverId);
}

void main() {
  late ForkDatabase db;
  late ReelStore store;
  late _Source source;
  late DateTime now;
  late ReelMetadata metadata;

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    now = DateTime.utc(2026, 3, 1, 20);
    store = ReelStore(database: () async => db, settings: () async => settings, clock: () => now);
    source = _Source();
    metadata = ReelMetadata(source: source, store: store);
  });

  tearDown(() => db.close());

  test("a fresh app row is used as is, with no read", () async {
    source.shared['a/1'] = (title: 'Harbor Lights', age: const Duration(days: 2));
    final item = await metadata.item('a', '1');
    expect(item?.title, 'Harbor Lights');
    expect(source.reads, isEmpty);
  });

  test('a miss makes one lean read, kept in the Reel cache only', () async {
    final item = await metadata.item('a', '1');
    expect(item?.title, 'Lean 1');
    expect(source.reads, ['a/1']);
    final kept = await store.cached(ReelMetadata.key('scope-a', '1'));
    expect(jsonDecode(kept!), {'ratingKey': '1', 'title': 'Lean 1'});

    final again = await metadata.item('a', '1');
    expect(again?.title, 'Lean 1');
    expect(source.reads, ['a/1'], reason: 'the kept row answers the second time');
  });

  test('an app row older than 7 days is read again', () async {
    source.shared['a/1'] = (title: 'Harbor Lights', age: const Duration(days: 8));
    final item = await metadata.item('a', '1');
    expect(item?.title, 'Lean 1');
    expect(source.reads, ['a/1']);
  });

  test('a kept lean row older than 7 days is read again', () async {
    await metadata.item('a', '1');
    now = now.add(const Duration(days: 8));
    await metadata.item('a', '1');
    expect(source.reads, ['a/1', 'a/1']);
  });

  test('a failed read falls back to an older row, else throws', () async {
    source.shared['a/1'] = (title: 'Harbor Lights', age: const Duration(days: 30));
    source.fail = StateError('offline');
    expect((await metadata.item('a', '1'))?.title, 'Harbor Lights');
    await expectLater(metadata.item('a', '2'), throwsStateError);
    expect(await store.cached(ReelMetadata.key('scope-a', '2')), isNull, reason: 'a failure is never kept');
  });

  test('an item the server does not have reads as null and keeps nothing', () async {
    source.missing = true;
    expect(await metadata.item('a', '1'), isNull);
    expect(await store.cached(ReelMetadata.key('scope-a', '1')), isNull);
  });

  test('a server the app has no client for reads nothing', () async {
    expect(await metadata.item('gone', '1'), isNull);
    expect(source.reads, isEmpty);
  });

  test('one read in flight per server; other servers do not wait', () async {
    source.gate = true;
    final one = metadata.item('a', '1');
    final two = metadata.item('a', '2');
    final other = metadata.item('b', '3');
    await pumpEventQueue();
    expect(source.reads, ['a/1', 'b/3'], reason: "a/2 waits for a/1; b's read starts at once");

    source.open['a/1']!.complete({'ratingKey': '1', 'title': 'Lean 1'});
    await pumpEventQueue();
    expect(source.reads, ['a/1', 'b/3', 'a/2']);

    source.open['a/2']!.complete({'ratingKey': '2', 'title': 'Lean 2'});
    source.open['b/3']!.complete({'ratingKey': '3', 'title': 'Lean 3'});
    expect(
      [
        for (final i in await Future.wait([one, two, other])) i?.title,
      ],
      ['Lean 1', 'Lean 2', 'Lean 3'],
    );
  });

  test('a failed read does not hold up the next one on that server', () async {
    source.gate = true;
    final one = metadata.item('a', '1');
    final two = metadata.item('a', '2');
    await pumpEventQueue();
    source.open['a/1']!.completeError(StateError('offline'));
    await expectLater(one, throwsStateError);
    await pumpEventQueue();
    expect(source.reads, ['a/1', 'a/2']);
    source.open['a/2']!.complete({'ratingKey': '2', 'title': 'Lean 2'});
    expect((await two)?.title, 'Lean 2');
  });
}
