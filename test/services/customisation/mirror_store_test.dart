import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/customisation/mirror_store.dart';

void main() {
  Map<String, Object?> snapshot() => {
    'homeLayout': {
      'curated': true,
      'revision': 3,
      'rows': [
        {'id': 'ai:abc', 'title': 'Cosy films', 'sources': <String>[]},
      ],
    },
    'comfortPaused': [
      {'traktId': 7, 'title': 'Frasier'},
    ],
    'settings': {'ai.history.index': '["abc"]'},
  };

  test('reads the snapshot', () async {
    final store = MirrorCustomisationStore(snapshot(), send: (_) => true);
    final home = await store.readHomeLayout();
    expect(home!.rows.single.id, 'ai:abc');
    expect(home.revision, 3);
    expect(await store.readComfortPaused(), {7: 'Frasier'});
    expect(await store.readSetting('ai.history.index'), '["abc"]');
  });

  test('sends edits and shows them at once', () async {
    final sent = <Map<String, Object?>>[];
    final store = MirrorCustomisationStore(
      snapshot(),
      send: (op) {
        sent.add(op);
        return true;
      },
    );
    await store.writeSetting('ai.history.xyz', '{}');
    await store.writeSetting('ai.history.index', null);
    await store.writeHomeLayout([], curated: false, revision: 4);
    expect(sent.map((o) => o['op']), ['setting', 'setting', 'home']);
    expect(await store.readSetting('ai.history.xyz'), '{}');
    expect(await store.readSetting('ai.history.index'), isNull);
    expect((await store.readHomeLayout())!.revision, 4);
  });

  test('is read-only while not connected', () async {
    final store = MirrorCustomisationStore(snapshot(), send: (_) => false);
    await expectLater(store.writeSetting('k', 'v'), throwsA(isA<MirrorReadOnlyException>()));
    expect(await store.readSetting('k'), isNull);
  });

  test('reads settings by key prefix from the snapshot and its own edits', () async {
    final store = MirrorCustomisationStore(snapshot(), send: (_) => true);
    await store.writeSetting('ai.history.xyz', '{}');
    expect(await store.readSettingsWithPrefix('ai.history.'), {'ai.history.index': '["abc"]', 'ai.history.xyz': '{}'});
    expect(await store.readSettingsWithPrefix('reel.'), isEmpty);
  });
}
