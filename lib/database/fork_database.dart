import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'fork_database.g.dart';

/// The fork's own customisation data (Home rows, Comfort pauses, the
/// Shortlist, small settings), in its own SQLite file next to Plezy's
/// database so upstream's schema and migrations stay untouched. Moved
/// between devices with Settings ▸ Backup & transfer.

/// Rows on Home, in order.
@DataClassName('HomeRowRecord')
class HomeRows extends Table {
  /// Home row id (see `HomeRowIds`).
  TextColumn get rowId => text()();
  IntColumn get position => integer()();
  TextColumn get title => text()();

  /// JSON array of `serverId|hub key` for Plex rows; `[]` otherwise.
  TextColumn get sourcesJson => text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {rowId};
}

/// Comfort shows taken out of the Random episode mix, by Trakt id.
@DataClassName('ComfortPausedRecord')
class ComfortPausedShows extends Table {
  IntColumn get traktId => integer()();
  TextColumn get title => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {traktId};
}

/// The Shortlist (planned): titles in order, each as catalog item JSON.
@DataClassName('ShortlistRecord')
class ShortlistItems extends Table {
  TextColumn get itemKey => text()();
  IntColumn get position => integer()();
  TextColumn get title => text()();
  TextColumn get itemJson => text()();
  IntColumn get addedAt => integer()();

  @override
  Set<Column> get primaryKey => {itemKey};
}

/// Small settings and bookkeeping, as JSON values.
@DataClassName('ForkSettingRecord')
class ForkSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// When each piece of customisation data last changed, for catching up with
/// another device (see `CatchUpSync`). A unit is `home`, `comfort`,
/// `shortlist` or `setting:<key>`; [stamp] is the change time in ms since the
/// epoch (1 for data that existed before stamps did). [deleted] marks a
/// removed setting so the removal reaches the other device too.
@DataClassName('SyncStampRecord')
class SyncStamps extends Table {
  TextColumn get unit => text()();
  IntColumn get stamp => integer()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {unit};
}

@DriftDatabase(tables: [HomeRows, ComfortPausedShows, ShortlistItems, ForkSettings, SyncStamps])
class ForkDatabase extends _$ForkDatabase {
  ForkDatabase(super.executor);

  /// Tests: an in-memory database.
  ForkDatabase.memory() : super(NativeDatabase.memory());

  static const String fileName = 'plezy_fork.db';

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(syncStamps);
        // Data from before stamps counts as the oldest possible change: it
        // still wins over a device that has nothing, and loses to any edit.
        await customStatement(
          "INSERT INTO sync_stamps (unit, stamp, deleted) SELECT 'setting:' || key, 1, 0 FROM fork_settings",
        );
        for (final (unit, table) in const [
          ('home', 'home_rows'),
          ('comfort', 'comfort_paused_shows'),
          ('shortlist', 'shortlist_items'),
        ]) {
          await customStatement(
            "INSERT INTO sync_stamps (unit, stamp, deleted) SELECT '$unit', 1, 0 WHERE EXISTS (SELECT 1 FROM $table)",
          );
        }
      }
    },
  );

  /// The database file beside Plezy's own.
  static Future<ForkDatabase> open() async {
    final folder = (Platform.isAndroid || Platform.isIOS)
        ? await getApplicationDocumentsDirectory()
        : await getApplicationSupportDirectory();
    if (!await folder.exists()) await folder.create(recursive: true);
    final file = File(p.join(folder.path, fileName));
    return ForkDatabase(NativeDatabase.createInBackground(file, setup: (db) => db.execute('PRAGMA journal_mode=WAL')));
  }
}
