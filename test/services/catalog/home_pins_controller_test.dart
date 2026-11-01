import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/trakt/trakt_user_list.dart';
import 'package:plezy/services/catalog/home_pins.dart';
import 'package:plezy/services/trackers/tracker_exceptions.dart';
import 'package:plezy/services/trackers/tracker_constants.dart';
import 'package:plezy/services/trackers/trakt/trakt_client.dart';

import '../../test_helpers/prefs.dart';

/// Trakt's "Plezy" list, in memory. [staleReads] makes list reads return
/// the description as it was before the last write (Trakt's reads lag).
class _FakeTrakt implements TraktClient {
  String? description;
  String? previousDescription;
  bool staleReads = false;
  int rateLimitNextWrites = 0;
  bool failWrites = false;
  int writes = 0;

  _FakeTrakt([this.description]);

  @override
  Future<List<TraktUserList>> getMyLists() async {
    final shown = staleReads ? previousDescription : description;
    if (description == null) return const [];
    return [TraktUserList(traktId: 1, slug: HomePinsController.listSlug, name: 'Plezy', description: shown)];
  }

  @override
  Future<void> updateMyListDescription(int listId, String newDescription) async {
    if (rateLimitNextWrites > 0) {
      rateLimitNextWrites--;
      throw TrackerRateLimitException(service: TrackerService.trakt, retryAfterSeconds: 1);
    }
    if (failWrites) throw StateError('offline');
    writes++;
    previousDescription = description;
    description = newDescription;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HomeRowEntry _row(String id) => (id: id, title: id, sources: const <String>[]);

List<String> _ids(HomeLayout layout) => [for (final r in layout.rows) r.id];

void main() {
  setUp(() => resetSharedPreferencesForTest());

  HomePinsController controller(_FakeTrakt trakt) => HomePinsController(trakt, retryDelay: (_) => Duration.zero);

  test('rows added in quick succession all reach Trakt, in order', () async {
    final trakt = _FakeTrakt(writeHomeLayout(null, defaultHomeLayout));
    final pins = controller(trakt);
    await pins.ensureLoaded();

    await Future.wait([
      pins.add([_row('a')]),
      pins.add([_row('b')]),
      pins.add([_row('c')]),
    ]);

    expect(_ids(pins.layout), ['cw', 'pb', 'a', 'b', 'c']);
    expect(_ids(parseHomeLayout(trakt.description)!), ['cw', 'pb', 'a', 'b', 'c']);
    expect(pins.hasUnsyncedChanges, isFalse);
  });

  test('a stale read from Trakt never replaces newer local rows', () async {
    final trakt = _FakeTrakt(writeHomeLayout(null, defaultHomeLayout));
    final pins = controller(trakt);
    await pins.ensureLoaded();
    await pins.add([_row('a')]);
    await pins.add([_row('b')]);

    // Home refreshes while Trakt still serves the copy from before 'b'.
    trakt.staleReads = true;
    await pins.ensureLoaded(refresh: true);

    expect(_ids(pins.layout), ['cw', 'pb', 'a', 'b']);
  });

  test('a newer layout saved on another device is adopted', () async {
    final trakt = _FakeTrakt(writeHomeLayout(null, defaultHomeLayout));
    final pins = controller(trakt);
    await pins.ensureLoaded();
    await pins.add([_row('a')]);

    trakt.description = writeHomeLayout(null, (rows: [_row('cw'), _row('z')], curated: true), revision: 99);
    await pins.ensureLoaded(refresh: true);

    expect(_ids(pins.layout), ['cw', 'z']);
  });

  test('a rate-limited save is retried instead of rolled back', () async {
    final trakt = _FakeTrakt(writeHomeLayout(null, defaultHomeLayout))..rateLimitNextWrites = 2;
    final pins = controller(trakt);
    await pins.ensureLoaded();

    await pins.add([_row('a')]);

    expect(_ids(pins.layout), ['cw', 'pb', 'a']);
    expect(_ids(parseHomeLayout(trakt.description)!), ['cw', 'pb', 'a']);
  });

  test('a failed save keeps the row on this device and syncs it on the next load', () async {
    final trakt = _FakeTrakt(writeHomeLayout(null, defaultHomeLayout))..failWrites = true;
    final pins = controller(trakt);
    await pins.ensureLoaded();

    await pins.add([_row('a')]);
    expect(_ids(pins.layout), ['cw', 'pb', 'a']);
    expect(pins.hasUnsyncedChanges, isTrue);

    // Next app start: the local copy (with its pending change) survives and
    // is pushed once Trakt accepts writes again.
    trakt.failWrites = false;
    final restarted = controller(trakt);
    await restarted.ensureLoaded();
    expect(_ids(restarted.layout), ['cw', 'pb', 'a']);
    expect(_ids(parseHomeLayout(trakt.description)!), ['cw', 'pb', 'a']);
    expect(restarted.hasUnsyncedChanges, isFalse);
  });
}
