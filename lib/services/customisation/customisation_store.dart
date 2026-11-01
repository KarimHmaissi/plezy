import 'dart:convert';

import 'package:drift/drift.dart';

import '../../database/fork_database.dart';

/// Home rows as stored: id, title and (for Plex rows) where to fetch them.
typedef StoredHomeRow = ({String id, String title, List<String> sources});

/// The fork's customisation data: Home rows, Comfort pauses, the Shortlist
/// and small settings. Local SQLite today ([LocalCustomisationStore]); kept
/// behind this interface so a cloud store can stand in later.
abstract interface class CustomisationStore {
  Future<({List<StoredHomeRow> rows, bool curated, int revision})?> readHomeLayout();
  Future<void> writeHomeLayout(List<StoredHomeRow> rows, {required bool curated, required int revision});

  Future<Map<int, String>> readComfortPaused();
  Future<void> writeComfortPaused(Map<int, String> paused);

  Future<String?> readSetting(String key);
  Future<void> writeSetting(String key, String? value);

  /// Everything, as one export document (see [CustomisationExport]).
  Future<Map<String, Object?>> exportAll();

  /// Replace everything with [data] (an already validated export).
  Future<void> importAll(Map<String, Object?> data);
}

class LocalCustomisationStore implements CustomisationStore {
  LocalCustomisationStore(this._db);

  final ForkDatabase _db;

  static const String _curatedKey = 'home.curated';
  static const String _revisionKey = 'home.revision';

  @override
  Future<({List<StoredHomeRow> rows, bool curated, int revision})?> readHomeLayout() async {
    final revision = await readSetting(_revisionKey);
    if (revision == null) return null;
    final rows = await (_db.select(_db.homeRows)..orderBy([(r) => OrderingTerm.asc(r.position)])).get();
    return (
      rows: [for (final r in rows) (id: r.rowId, title: r.title, sources: _decodeSources(r.sourcesJson))],
      curated: await readSetting(_curatedKey) != 'false',
      revision: int.tryParse(revision) ?? 0,
    );
  }

  @override
  Future<void> writeHomeLayout(List<StoredHomeRow> rows, {required bool curated, required int revision}) =>
      _db.transaction(() async {
        await _db.delete(_db.homeRows).go();
        await _db.batch((b) {
          b.insertAll(_db.homeRows, [
            for (final (i, row) in rows.indexed)
              HomeRowsCompanion.insert(
                rowId: row.id,
                position: i,
                title: row.title,
                sourcesJson: Value(jsonEncode(row.sources)),
              ),
          ]);
        });
        await writeSetting(_curatedKey, curated ? 'true' : 'false');
        await writeSetting(_revisionKey, '$revision');
      });

  @override
  Future<Map<int, String>> readComfortPaused() async {
    final rows = await _db.select(_db.comfortPausedShows).get();
    return {for (final r in rows) r.traktId: r.title};
  }

  @override
  Future<void> writeComfortPaused(Map<int, String> paused) => _db.transaction(() async {
    await _db.delete(_db.comfortPausedShows).go();
    await _db.batch((b) {
      b.insertAll(_db.comfortPausedShows, [
        for (final MapEntry(key: id, value: title) in paused.entries)
          ComfortPausedShowsCompanion.insert(traktId: Value(id), title: Value(title)),
      ]);
    });
  });

  @override
  Future<String?> readSetting(String key) async =>
      (await (_db.select(_db.forkSettings)..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  @override
  Future<void> writeSetting(String key, String? value) async {
    if (value == null) {
      await (_db.delete(_db.forkSettings)..where((s) => s.key.equals(key))).go();
    } else {
      await _db.into(_db.forkSettings).insertOnConflictUpdate(ForkSettingsCompanion.insert(key: key, value: value));
    }
  }

  @override
  Future<Map<String, Object?>> exportAll() async {
    final home = await readHomeLayout();
    final shortlist = await (_db.select(_db.shortlistItems)..orderBy([(r) => OrderingTerm.asc(r.position)])).get();
    final settings = await _db.select(_db.forkSettings).get();
    return {
      'homeLayout': home == null
          ? null
          : {
              'curated': home.curated,
              'revision': home.revision,
              'rows': [
                for (final r in home.rows) {'id': r.id, 'title': r.title, 'sources': r.sources},
              ],
            },
      'comfortPaused': [
        for (final MapEntry(key: id, value: title) in (await readComfortPaused()).entries)
          {'traktId': id, 'title': title},
      ],
      'shortlist': [
        for (final s in shortlist) {'key': s.itemKey, 'title': s.title, 'item': s.itemJson, 'addedAt': s.addedAt},
      ],
      'settings': {
        for (final s in settings)
          if (s.key != _curatedKey && s.key != _revisionKey) s.key: s.value,
      },
    };
  }

  @override
  Future<void> importAll(Map<String, Object?> data) => _db.transaction(() async {
    await _db.delete(_db.homeRows).go();
    await _db.delete(_db.comfortPausedShows).go();
    await _db.delete(_db.shortlistItems).go();
    await _db.delete(_db.forkSettings).go();
    final home = data['homeLayout'];
    if (home is Map) {
      await writeHomeLayout(
        [
          for (final r in (home['rows'] as List? ?? const []).whereType<Map>())
            (
              id: r['id'] as String,
              title: r['title'] as String? ?? r['id'] as String,
              sources: [...(r['sources'] as List? ?? const []).whereType<String>()],
            ),
        ],
        curated: home['curated'] != false,
        revision: home['revision'] is int ? home['revision'] as int : 1,
      );
    }
    await writeComfortPaused({
      for (final p in (data['comfortPaused'] as List? ?? const []).whereType<Map>())
        if (p['traktId'] case final int id) id: p['title'] as String? ?? '',
    });
    await _db.batch((b) {
      b.insertAll(_db.shortlistItems, [
        for (final (i, s) in (data['shortlist'] as List? ?? const []).whereType<Map>().indexed)
          ShortlistItemsCompanion.insert(
            itemKey: s['key'] as String,
            position: i,
            title: s['title'] as String? ?? '',
            itemJson: s['item'] as String? ?? '{}',
            addedAt: s['addedAt'] is int ? s['addedAt'] as int : 0,
          ),
      ]);
    });
    final settings = data['settings'];
    if (settings is Map) {
      for (final MapEntry(:key, :value) in settings.entries) {
        if (key is String && value is String) await writeSetting(key, value);
      }
    }
  });

  static List<String> _decodeSources(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? [...decoded.whereType<String>()] : const [];
    } catch (_) {
      return const [];
    }
  }
}

/// The export file: one versioned JSON document holding all of
/// [CustomisationStore.exportAll].
abstract final class CustomisationExport {
  static const String format = 'plezy-fork-backup';
  static const int schemaVersion = 1;

  static String encode(Map<String, Object?> data, {required String appVersion, DateTime? now}) =>
      const JsonEncoder.withIndent('  ').convert({
        'format': format,
        'schemaVersion': schemaVersion,
        'appVersion': appVersion,
        'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
        ...data,
      });

  /// The data in [text], or a [FormatException] saying why it can't be used.
  static Map<String, Object?> decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      throw const FormatException('notJson');
    }
    if (json is! Map<String, Object?> || json['format'] != format) throw const FormatException('notBackup');
    final version = json['schemaVersion'];
    if (version is! int) throw const FormatException('notBackup');
    if (version > schemaVersion) throw const FormatException('newerVersion');
    final home = json['homeLayout'];
    if (home != null) {
      if (home is! Map || home['rows'] is! List) throw const FormatException('notBackup');
      for (final r in home['rows'] as List) {
        if (r is! Map || r['id'] is! String) throw const FormatException('notBackup');
      }
    }
    return json;
  }

  /// "7 Home rows, 3 paused Comfort shows" counts for the import prompt.
  static ({int homeRows, int comfortPaused, int shortlist}) summary(Map<String, Object?> data) => (
    homeRows: ((data['homeLayout'] as Map?)?['rows'] as List?)?.length ?? 0,
    comfortPaused: (data['comfortPaused'] as List?)?.length ?? 0,
    shortlist: (data['shortlist'] as List?)?.length ?? 0,
  );
}

/// The app's customisation store, opened on first use.
abstract final class Customisation {
  static Future<CustomisationStore>? _store;

  static Future<CustomisationStore> get store =>
      _store ??= ForkDatabase.open().then<CustomisationStore>(LocalCustomisationStore.new);

  /// Tests: use [store] instead of the on-disk database.
  static void debugSetStore(CustomisationStore? store) => _store = store == null ? null : Future.value(store);
}
