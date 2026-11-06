import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

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
        Customisation.localWrites.value++;
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
        await _stamp(SyncUnits.home);
      });

  @override
  Future<Map<int, String>> readComfortPaused() async {
    final rows = await _db.select(_db.comfortPausedShows).get();
    return {for (final r in rows) r.traktId: r.title};
  }

  @override
  Future<void> writeComfortPaused(Map<int, String> paused) => _db.transaction(() async {
    Customisation.localWrites.value++;
    await _db.delete(_db.comfortPausedShows).go();
    await _db.batch((b) {
      b.insertAll(_db.comfortPausedShows, [
        for (final MapEntry(key: id, value: title) in paused.entries)
          ComfortPausedShowsCompanion.insert(traktId: Value(id), title: Value(title)),
      ]);
    });
    await _stamp(SyncUnits.comfort);
  });

  @override
  Future<String?> readSetting(String key) async =>
      (await (_db.select(_db.forkSettings)..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  @override
  Future<void> writeSetting(String key, String? value) => _writeSetting(key, value);

  Future<void> _writeSetting(String key, String? value, {int? stamp}) async {
    Customisation.localWrites.value++;
    if (value == null) {
      await (_db.delete(_db.forkSettings)..where((s) => s.key.equals(key))).go();
    } else {
      await _db.into(_db.forkSettings).insertOnConflictUpdate(ForkSettingsCompanion.insert(key: key, value: value));
    }
    if (SyncUnits.syncsSetting(key)) await _stamp(SyncUnits.setting(key), at: stamp, deleted: value == null);
  }

  /// Record that [unit] changed now (or at [at], for data from another
  /// device), for `CatchUpSync`.
  Future<void> _stamp(String unit, {int? at, bool deleted = false}) => _db
      .into(_db.syncStamps)
      .insertOnConflictUpdate(
        SyncStampsCompanion.insert(
          unit: unit,
          stamp: at ?? DateTime.now().millisecondsSinceEpoch,
          deleted: Value(deleted),
        ),
      );

  /// When each syncable unit last changed on this device.
  Future<Map<String, SyncStamp>> readSyncStamps() async => {
    for (final r in await _db.select(_db.syncStamps).get())
      if (SyncUnits.isSyncable(r.unit)) r.unit: (stamp: r.stamp, deleted: r.deleted),
  };

  /// [units] as they are on this device, each with its stamp, to send to
  /// another device (see [applySyncUnits]).
  Future<Map<String, Object?>> readSyncUnits(Iterable<String> units) async {
    final stamps = await readSyncStamps();
    final out = <String, Object?>{};
    for (final unit in units) {
      final stamp = stamps[unit];
      if (stamp == null) continue;
      final Object? value;
      if (stamp.deleted) {
        value = null;
      } else if (unit == SyncUnits.home) {
        final home = await readHomeLayout();
        value = home == null
            ? null
            : {
                'curated': home.curated,
                'revision': home.revision,
                'rows': [
                  for (final r in home.rows) {'id': r.id, 'title': r.title, 'sources': r.sources},
                ],
              };
      } else if (unit == SyncUnits.comfort) {
        value = [
          for (final MapEntry(key: id, value: title) in (await readComfortPaused()).entries)
            {'traktId': id, 'title': title},
        ];
      } else if (unit == SyncUnits.shortlist) {
        value = await _shortlistJson();
      } else {
        value = await readSetting(SyncUnits.settingKey(unit)!);
      }
      out[unit] = {'stamp': stamp.stamp, 'deleted': stamp.deleted, 'value': value};
    }
    return out;
  }

  /// Take the units another device sent ([readSyncUnits]) that changed there
  /// after they last changed here. Returns the units taken.
  Future<Set<String>> applySyncUnits(Map<String, Object?> units) => _db.transaction(() async {
    final local = await readSyncStamps();
    final taken = <String>{};
    for (final MapEntry(key: unit, value: raw) in units.entries) {
      if (!SyncUnits.isSyncable(unit) || raw is! Map) continue;
      final stamp = raw['stamp'];
      if (stamp is! int || stamp <= (local[unit]?.stamp ?? 0)) continue;
      final deleted = raw['deleted'] == true;
      final value = raw['value'];
      if (unit == SyncUnits.home) {
        if (value is! Map) continue;
        await writeHomeLayout(
          [
            for (final r in (value['rows'] as List? ?? const []).whereType<Map>())
              if (r['id'] case final String id)
                (
                  id: id,
                  title: r['title'] as String? ?? id,
                  sources: [...(r['sources'] as List? ?? const []).whereType<String>()],
                ),
          ],
          curated: value['curated'] != false,
          revision: value['revision'] is int ? value['revision'] as int : 1,
        );
      } else if (unit == SyncUnits.comfort) {
        await writeComfortPaused({
          for (final p in (value as List? ?? const []).whereType<Map>())
            if (p['traktId'] case final int id) id: p['title'] as String? ?? '',
        });
      } else if (unit == SyncUnits.shortlist) {
        await _writeShortlist(value as List? ?? const []);
      } else {
        if (!deleted && value is! String) continue;
        await _writeSetting(SyncUnits.settingKey(unit)!, deleted ? null : value as String, stamp: stamp);
        taken.add(unit);
        continue;
      }
      // Whole units keep the other device's stamp, not the time of this write.
      await _stamp(unit, at: stamp, deleted: deleted);
      taken.add(unit);
    }
    return taken;
  });

  Future<List<Map<String, Object?>>> _shortlistJson() async => [
    for (final s in await (_db.select(_db.shortlistItems)..orderBy([(r) => OrderingTerm.asc(r.position)])).get())
      {'key': s.itemKey, 'title': s.title, 'item': s.itemJson, 'addedAt': s.addedAt},
  ];

  Future<void> _writeShortlist(List<dynamic> items) async {
    Customisation.localWrites.value++;
    await _db.delete(_db.shortlistItems).go();
    await _db.batch((b) {
      b.insertAll(_db.shortlistItems, [
        for (final (i, s) in items.whereType<Map>().indexed)
          if (s['key'] case final String key)
            ShortlistItemsCompanion.insert(
              itemKey: key,
              position: i,
              title: s['title'] as String? ?? '',
              itemJson: s['item'] as String? ?? '{}',
              addedAt: s['addedAt'] is int ? s['addedAt'] as int : 0,
            ),
      ]);
    });
  }

  @override
  Future<Map<String, Object?>> exportAll() async {
    final home = await readHomeLayout();
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
      'shortlist': await _shortlistJson(),
      'settings': {
        for (final s in settings)
          if (s.key != _curatedKey && s.key != _revisionKey) s.key: s.value,
      },
    };
  }

  @override
  Future<void> importAll(Map<String, Object?> data) => _db.transaction(() async {
    Customisation.localWrites.value++;
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
    await _writeShortlist(data['shortlist'] as List? ?? const []);
    await _stamp(SyncUnits.shortlist);
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

/// A unit's last change on one device: when (ms since the epoch) and whether
/// it was a removal.
typedef SyncStamp = ({int stamp, bool deleted});

/// The pieces of customisation data that catch up between devices (see
/// `CatchUpSync`), each kept whole: the newer side's copy wins.
abstract final class SyncUnits {
  static const String home = 'home';
  static const String comfort = 'comfort';
  static const String shortlist = 'shortlist';
  static const String _settingPrefix = 'setting:';

  static String setting(String key) => '$_settingPrefix$key';

  /// The setting key of a `setting:` unit, else null.
  static String? settingKey(String unit) =>
      unit.startsWith(_settingPrefix) ? unit.substring(_settingPrefix.length) : null;

  /// Settings that belong to this device only: Home's own bookkeeping (part of
  /// [home]), whether the Reel's Home row was seated here (only the TV seats
  /// it, `ReelHomeRow`), the AI answer order (rebuilt from the answers after a
  /// sync), this device's AI spend, one-off migrations and caches of Trakt
  /// data.
  static bool syncsSetting(String key) =>
      key != 'home.curated' &&
      key != 'home.revision' &&
      key != 'reel.homeRowSeated' &&
      key != 'reel.homeRowRechecked' &&
      key != 'ai.history.index' &&
      !key.startsWith('ai.spend.') &&
      key != 'comfort.pausedMigrated' &&
      key != 'comfort.shows';

  static bool isSyncable(String unit) {
    final key = settingKey(unit);
    return key != null ? syncsSetting(key) : unit == home || unit == comfort || unit == shortlist;
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

  static Future<ForkDatabase>? _database;

  /// This device's own fork database (one connection for the whole app),
  /// also when [store] mirrors a TV. The Reel keeps its per-device events
  /// and caches here.
  static Future<ForkDatabase> get localDatabase => _database ??= ForkDatabase.open();

  /// Tests: use [db] as this device's database.
  static void debugSetLocalDatabase(ForkDatabase? db) => _database = db == null ? null : Future.value(db);

  static Future<CustomisationStore> get store =>
      _store ??= localDatabase.then<CustomisationStore>(LocalCustomisationStore.new);

  /// Tests: use [store] instead of the on-disk database.
  static void debugSetStore(CustomisationStore? store) => _store = store == null ? null : Future.value(store);

  /// Bumped on every write to this device's own database; a host sends
  /// connected phones a fresh snapshot after it (see `MirrorHost`).
  static final ValueNotifier<int> localWrites = ValueNotifier(0);

  /// Bumped when the data was replaced or changed from elsewhere (a phone
  /// mirroring its TV got a new snapshot; a TV applied a phone's edit), so
  /// screens holding a copy reload it.
  static final ValueNotifier<int> changed = ValueNotifier(0);

  /// Whether this is a phone showing a connected TV's data ([useMirror]).
  static bool isMirror = false;

  /// Phone: read the TV's data from [store] (and send edits to it) instead
  /// of this device's own database, which stays untouched.
  static void useMirror(CustomisationStore store) {
    _store = Future.value(store);
    isMirror = true;
    changed.value++;
  }

  /// Phone: back to this device's own database after mirroring.
  static void useLocal() {
    if (!isMirror) return;
    _store = null;
    isMirror = false;
    changed.value++;
  }
}
