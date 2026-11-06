import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/copy_fallback.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/services/broken_copies.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

void main() {
  var now = DateTime.utc(2026, 11, 6, 22);
  final store = BrokenCopies.instance;

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    now = DateTime.utc(2026, 11, 6, 22);
    store.resetForTesting(now: () => now);
  });

  final film = testMediaItem(
    id: '101',
    serverId: 'server-a',
    mediaVersions: const [
      MediaVersion(id: 'a4k', height: 2160),
      MediaVersion(id: 'a1080', height: 1080),
    ],
  );
  final fourK = copySourceKey(film, film.mediaVersions![0]);
  final hd = copySourceKey(film, film.mediaVersions![1]);

  test('a failure is remembered for the run, and on disk for 24 hours', () async {
    await store.markBroken(fourK);
    expect(store.isBroken(fourK), isTrue);
    expect(store.isBroken(hd), isFalse);

    // The app restarts an hour later: the stored failure still counts.
    now = now.add(const Duration(hours: 1));
    store.restartForTesting();
    await store.ensureLoaded();
    expect(store.isBroken(fourK), isTrue);

    // A day later it has expired.
    now = now.add(const Duration(hours: 24));
    store.restartForTesting();
    await store.ensureLoaded();
    expect(store.isBroken(fourK), isFalse);
  });

  test('within the run a failure holds even past the stored window', () async {
    await store.markBroken(fourK);
    now = now.add(const Duration(hours: 30));
    expect(store.isBroken(fourK), isTrue);
  });

  test('a copy that plays is forgotten at once, on disk too', () async {
    await store.markBroken(fourK);
    await store.clear(fourK);
    expect(store.isBroken(fourK), isFalse);
    store.restartForTesting();
    await store.ensureLoaded();
    expect(store.isBroken(fourK), isFalse);
  });

  test('a copy is broken only when every version is', () async {
    await store.markBroken(fourK);
    expect(store.isCopyBroken(film), isFalse);
    await store.markBroken(hd);
    expect(store.isCopyBroken(film), isTrue);
    final bare = testMediaItem(id: '202', serverId: 'server-b');
    await store.markBroken(copySourceKey(bare, null));
    expect(store.isCopyBroken(bare), isTrue);
  });

  test('keys hold the server, item and version ids only, and the store is capped', () async {
    expect(fourK, 'server-a|101|a4k');
    for (var i = 0; i < BrokenCopies.maxEntries + 20; i++) {
      now = now.add(const Duration(seconds: 1));
      await store.markBroken('server-x|$i|v');
    }
    final stored = SettingsService.instance.read(SettingsService.brokenCopies);
    expect(stored.length, BrokenCopies.maxEntries);
    expect(stored.containsKey('server-x|0|v'), isFalse, reason: 'the oldest go first');
  });
}
