import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/ai_history.dart';
import 'package:plezy/services/customisation/customisation_store.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/prefs.dart';

AiHistoryEntry _entry(String id, {String? request}) {
  final item = testMediaItem(id: 'rk-$id', title: 'Film $id', serverId: 's1', year: 2020);
  return AiHistoryEntry(
    id: id,
    request: request ?? 'request $id',
    intro: 'Intro $id',
    createdAt: DateTime(2026, 11, 1),
    items: [item],
    reasons: {item.globalKey: 'Because $id'},
  );
}

void main() {
  late ForkDatabase db;

  setUp(() {
    resetSharedPreferencesForTest();
    db = ForkDatabase.memory();
    Customisation.debugSetStore(LocalCustomisationStore(db));
  });
  tearDown(() async {
    Customisation.debugSetStore(null);
    await db.close();
  });

  test('answers are saved newest first and read back with their picks and reasons', () async {
    await AiHistory.add(_entry('a'));
    await AiHistory.add(_entry('b'));
    await AiHistory.add(_entry('c'));

    expect(await AiHistory.count(), 3);
    final page = await AiHistory.page(limit: 2);
    expect([for (final e in page) e.id], ['c', 'b']);
    expect((await AiHistory.page(offset: 2, limit: 2)).single.id, 'a');

    final c = page.first;
    expect(c.request, 'request c');
    expect(c.intro, 'Intro c');
    expect(c.items.single.title, 'Film c');
    expect(c.reasons[c.items.single.globalKey], 'Because c');
  });

  test('refresh replaces an answer in place; delete removes it', () async {
    await AiHistory.add(_entry('a'));
    await AiHistory.add(_entry('b'));
    final refreshed = _entry('a');
    await AiHistory.replace(
      AiHistoryEntry(
        id: 'a',
        request: refreshed.request,
        intro: 'New intro',
        createdAt: refreshed.createdAt,
        items: refreshed.items,
        reasons: refreshed.reasons,
      ),
    );
    expect([for (final e in await AiHistory.page(limit: 10)) e.id], ['b', 'a']);
    expect((await AiHistory.get('a'))!.intro, 'New intro');

    await AiHistory.remove('b');
    expect([for (final e in await AiHistory.page(limit: 10)) e.id], ['a']);
    expect(await AiHistory.get('b'), isNull);
  });

  test('keeps at most maxEntries, dropping the oldest', () async {
    for (var i = 0; i < AiHistory.maxEntries + 2; i++) {
      await AiHistory.add(_entry('e$i'));
    }
    expect(await AiHistory.count(), AiHistory.maxEntries);
    expect(await AiHistory.get('e0'), isNull);
    expect(await AiHistory.get('e1'), isNull);
    expect(await AiHistory.get('e2'), isNotNull);
  });
}
