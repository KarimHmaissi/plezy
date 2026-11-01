import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'index_database.g.dart';

/// Every movie and show on the user's Plex servers, one row per title per
/// library, for instant search and the AI helper. A cache: safe to delete,
/// rebuilt from Plex, never backed up.
@DataClassName('IndexedTitle')
class IndexTitles extends Table {
  /// `serverId:ratingKey`.
  TextColumn get id => text()();
  TextColumn get serverId => text()();
  TextColumn get serverName => text()();
  TextColumn get libraryKey => text()();
  TextColumn get libraryTitle => text()();
  TextColumn get ratingKey => text()();

  /// `movie` or `show`.
  TextColumn get type => text()();
  TextColumn get title => text()();
  TextColumn get originalTitle => text().nullable()();
  IntColumn get year => integer().nullable()();

  /// `YYYY-MM-DD` (a show's first air date).
  TextColumn get releaseDate => text().nullable()();

  /// Seconds since epoch, as Plex reports them.
  IntColumn get addedAt => integer().nullable()();
  IntColumn get updatedAt => integer().nullable()();
  IntColumn get durationMinutes => integer().nullable()();
  TextColumn get contentRating => text().nullable()();

  /// Plex audience rating (usually IMDb) and critic rating, 0-10.
  RealColumn get audienceRating => real().nullable()();
  RealColumn get criticRating => real().nullable()();
  TextColumn get studio => text().nullable()();
  TextColumn get summary => text().nullable()();
  TextColumn get tagline => text().nullable()();

  /// Lists joined with `|`.
  TextColumn get genres => text().withDefault(const Constant(''))();
  TextColumn get countries => text().withDefault(const Constant(''))();
  TextColumn get directors => text().withDefault(const Constant(''))();
  TextColumn get writers => text().withDefault(const Constant(''))();
  TextColumn get cast => text().withDefault(const Constant(''))();
  TextColumn get collections => text().withDefault(const Constant(''))();
  TextColumn get imdb => text().nullable()();
  TextColumn get tmdb => text().nullable()();
  TextColumn get tvdb => text().nullable()();

  /// The same title across 4K copies and servers (external id, else
  /// title + year).
  TextColumn get groupKey => text()();

  /// Shows: episodes and episodes watched.
  IntColumn get episodeCount => integer().nullable()();
  IntColumn get watchedEpisodeCount => integer().nullable()();

  /// The signed-in user's watch state.
  IntColumn get viewCount => integer().nullable()();
  IntColumn get lastViewedAt => integer().nullable()();
  IntColumn get viewOffsetMs => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// How far each library has been indexed.
@DataClassName('IndexedLibrary')
class IndexLibraries extends Table {
  /// `serverId:libraryKey`.
  TextColumn get id => text()();
  TextColumn get serverId => text()();
  TextColumn get serverName => text()();
  TextColumn get libraryKey => text()();
  TextColumn get title => text()();
  TextColumn get type => text()();

  /// Titles Plex reports for the library, and how many are indexed.
  IntColumn get totalCount => integer().withDefault(const Constant(0))();
  IntColumn get indexedCount => integer().withDefault(const Constant(0))();

  /// Next page offset while a full build is in progress; null when done.
  IntColumn get buildCursor => integer().nullable()();

  /// Milliseconds since epoch.
  IntColumn get lastFullBuildAt => integer().nullable()();
  IntColumn get lastUpdateAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [IndexTitles, IndexLibraries])
class IndexDatabase extends _$IndexDatabase {
  IndexDatabase(super.executor);

  /// Tests: an in-memory database.
  IndexDatabase.memory() : super(NativeDatabase.memory());

  static const String fileName = 'plezy_index.db';

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await customStatement('CREATE INDEX idx_titles_type ON index_titles (type)');
      await customStatement('CREATE INDEX idx_titles_group ON index_titles (group_key)');
      await customStatement('CREATE INDEX idx_titles_added ON index_titles (added_at)');
      await customStatement('CREATE INDEX idx_titles_release ON index_titles (release_date)');
      await customStatement('CREATE INDEX idx_titles_library ON index_titles (server_id, library_key)');
      // Full-text search over the words people search by, kept in step with
      // index_titles by triggers.
      await customStatement('''
        CREATE VIRTUAL TABLE titles_fts USING fts5(
          title, original_title, summary, tagline, "cast", directors, collections,
          content='index_titles', content_rowid='rowid', tokenize='porter unicode61 remove_diacritics 2'
        )''');
      await customStatement('''
        CREATE TRIGGER titles_fts_insert AFTER INSERT ON index_titles BEGIN
          INSERT INTO titles_fts(rowid, title, original_title, summary, tagline, "cast", directors, collections)
          VALUES (new.rowid, new.title, new.original_title, new.summary, new.tagline, new."cast", new.directors, new.collections);
        END''');
      await customStatement('''
        CREATE TRIGGER titles_fts_delete AFTER DELETE ON index_titles BEGIN
          INSERT INTO titles_fts(titles_fts, rowid, title, original_title, summary, tagline, "cast", directors, collections)
          VALUES ('delete', old.rowid, old.title, old.original_title, old.summary, old.tagline, old."cast", old.directors, old.collections);
        END''');
      await customStatement('''
        CREATE TRIGGER titles_fts_update AFTER UPDATE ON index_titles BEGIN
          INSERT INTO titles_fts(titles_fts, rowid, title, original_title, summary, tagline, "cast", directors, collections)
          VALUES ('delete', old.rowid, old.title, old.original_title, old.summary, old.tagline, old."cast", old.directors, old.collections);
          INSERT INTO titles_fts(rowid, title, original_title, summary, tagline, "cast", directors, collections)
          VALUES (new.rowid, new.title, new.original_title, new.summary, new.tagline, new."cast", new.directors, new.collections);
        END''');
    },
  );

  static Future<File> file() async {
    final folder = (Platform.isAndroid || Platform.isIOS)
        ? await getApplicationDocumentsDirectory()
        : await getApplicationSupportDirectory();
    if (!await folder.exists()) await folder.create(recursive: true);
    return File(p.join(folder.path, fileName));
  }

  static Future<IndexDatabase> open() async => IndexDatabase(
    NativeDatabase.createInBackground(
      await file(),
      setup: (db) {
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA synchronous=NORMAL');
      },
    ),
  );
}
