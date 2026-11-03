import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import '../plex_client.dart';
import 'index_database.dart';
import 'index_mapping.dart';

/// What the index is doing, for Settings and logs.
enum LibraryIndexPhase { idle, building, updating, failed }

@immutable
class LibraryIndexStatus {
  const LibraryIndexStatus({
    this.phase = LibraryIndexPhase.idle,
    this.indexed = 0,
    this.total = 0,
    this.requests = 0,
    this.currentLibrary,
    this.error,
  });

  final LibraryIndexPhase phase;
  final int indexed;
  final int total;
  final int requests;
  final String? currentLibrary;
  final String? error;

  LibraryIndexStatus copyWith({
    LibraryIndexPhase? phase,
    int? indexed,
    int? total,
    int? requests,
    String? currentLibrary,
    String? error,
  }) => LibraryIndexStatus(
    phase: phase ?? this.phase,
    indexed: indexed ?? this.indexed,
    total: total ?? this.total,
    requests: requests ?? this.requests,
    currentLibrary: currentLibrary ?? this.currentLibrary,
    error: error ?? this.error,
  );
}

/// A source of Plex library pages: one Plex server (see [PlexClient]'s
/// `fetchIndexSections` / `fetchIndexPage`). An interface so tests can fake
/// a server.
abstract interface class IndexSource {
  String get serverId;
  String get serverName;
  Future<List<Map<String, dynamic>>> sections();
  Future<({List<Map<String, dynamic>> items, int total})> page(
    String sectionKey, {
    required int plexType,
    required int start,
    required int size,
    Map<String, String> filters,
  });
}

class PlexIndexSource implements IndexSource {
  PlexIndexSource(this._client);

  final PlexClient _client;

  @override
  String get serverId => _client.serverId.value;

  @override
  String get serverName => _client.serverName ?? serverId;

  @override
  Future<List<Map<String, dynamic>>> sections() => _client.fetchIndexSections();

  @override
  Future<({List<Map<String, dynamic>> items, int total})> page(
    String sectionKey, {
    required int plexType,
    required int start,
    required int size,
    Map<String, String> filters = const {},
  }) => _client.fetchIndexPage(sectionKey, plexType: plexType, start: start, size: size, filters: filters);
}

/// Every movie and show on the user's Plex servers in a local SQLite index
/// (see [IndexDatabase]), built gently and kept up to date.
///
/// The first build lists each movie and show library in pages of
/// [pageSize], one request at a time with [requestGap] between requests,
/// resuming where it stopped if interrupted. After that, [update] asks each
/// library only for titles added or changed since the last check.
class LibraryIndex {
  LibraryIndex({Future<IndexDatabase>? openDatabase, this.requestGap = const Duration(milliseconds: 1500)})
    : _database = openDatabase;

  static LibraryIndex? _instance;
  static LibraryIndex get instance => _instance ??= LibraryIndex();

  static const int pageSize = 500;

  /// How long the index can go without an update before one runs.
  static const Duration updateEvery = Duration(hours: 6);

  final Duration requestGap;
  Future<IndexDatabase>? _database;
  Future<IndexDatabase> get database => _database ??= IndexDatabase.open();

  final ValueNotifier<LibraryIndexStatus> status = ValueNotifier(const LibraryIndexStatus());
  Future<void>? _running;
  Timer? _timer;

  /// Build the index if any library hasn't been fully indexed yet, else
  /// update it when it's older than [updateEvery]; then keep updating every
  /// [updateEvery] while the app runs. Safe to call repeatedly.
  Future<void> start(List<IndexSource> Function() sources) {
    _timer ??= Timer.periodic(updateEvery, (_) => unawaited(_run(sources(), force: true)));
    return _run(sources());
  }

  Future<void> _run(List<IndexSource> sources, {bool force = false}) {
    if (sources.isEmpty) return Future.value();
    return _running ??= () async {
      try {
        await build(sources);
        final db = await database;
        final libraries = await db.select(db.indexLibraries).get();
        final oldest = libraries.map((l) => l.lastUpdateAt ?? 0).fold<int?>(null, (a, b) => a == null || b < a ? b : a);
        final stale = oldest == null || DateTime.now().millisecondsSinceEpoch - oldest > updateEvery.inMilliseconds;
        if (force || stale) await update(sources);
      } catch (e, st) {
        appLogger.w('Library index: run failed', error: e, stackTrace: st);
        status.value = status.value.copyWith(phase: LibraryIndexPhase.failed, error: '$e');
      } finally {
        _running = null;
      }
    }();
  }

  int _requests = 0;

  Future<T> _request<T>(Future<T> Function() call) async {
    if (_requests > 0) await Future<void>.delayed(requestGap);
    _requests++;
    status.value = status.value.copyWith(requests: _requests);
    return call();
  }

  static int? _plexType(String? libraryType) => switch (libraryType) {
    'movie' => 1,
    'show' => 2,
    _ => null,
  };

  /// Index every movie and show library not yet fully indexed, resuming
  /// partial builds.
  Future<void> build(List<IndexSource> sources) async {
    final db = await database;
    for (final source in sources) {
      final sections = await _request(source.sections);
      for (final section in sections) {
        final type = section['type'] as String?;
        final plexType = _plexType(type);
        if (plexType == null) continue;
        final key = '${section['key']}';
        final id = '${source.serverId}:$key';
        final title = '${section['title'] ?? key}';
        final existing = await (db.select(db.indexLibraries)..where((l) => l.id.equals(id))).getSingleOrNull();
        if (existing?.lastFullBuildAt != null) continue;
        var start = existing?.buildCursor ?? 0;
        var indexed = existing?.indexedCount ?? 0;
        status.value = status.value.copyWith(
          phase: LibraryIndexPhase.building,
          currentLibrary: '${source.serverName} · $title',
        );
        appLogger.i('Library index: building ${source.serverName} · $title from $start');
        while (true) {
          final page = await _request(() => source.page(key, plexType: plexType, start: start, size: pageSize));
          await db.batch((b) {
            b.insertAllOnConflictUpdate(db.indexTitles, [
              for (final item in page.items)
                if (item['ratingKey'] != null)
                  indexRowFromPlex(
                    item,
                    serverId: source.serverId,
                    serverName: source.serverName,
                    libraryKey: key,
                    libraryTitle: title,
                  ),
            ]);
          });
          start += page.items.length;
          indexed = start;
          final done = page.items.isEmpty || start >= page.total;
          await db
              .into(db.indexLibraries)
              .insertOnConflictUpdate(
                IndexLibrariesCompanion.insert(
                  id: id,
                  serverId: source.serverId,
                  serverName: source.serverName,
                  libraryKey: key,
                  title: title,
                  type: type!,
                  totalCount: Value(page.total),
                  indexedCount: Value(indexed),
                  buildCursor: Value(done ? null : start),
                  lastFullBuildAt: Value(done ? DateTime.now().millisecondsSinceEpoch : null),
                  lastUpdateAt: Value(done ? DateTime.now().millisecondsSinceEpoch : existing?.lastUpdateAt),
                ),
              );
          status.value = status.value.copyWith(indexed: status.value.indexed + page.items.length);
          if (done) break;
        }
      }
    }
    status.value = status.value.copyWith(phase: LibraryIndexPhase.idle);
  }

  /// Bring fully indexed libraries up to date: titles added or changed since
  /// each library's last update (with a minute of overlap).
  Future<void> update(List<IndexSource> sources) async {
    final db = await database;
    final libraries = await (db.select(db.indexLibraries)..where((l) => l.lastFullBuildAt.isNotNull())).get();
    status.value = status.value.copyWith(phase: LibraryIndexPhase.updating);
    for (final library in libraries) {
      final source = sources.where((s) => s.serverId == library.serverId).firstOrNull;
      final plexType = _plexType(library.type);
      if (source == null || plexType == null) continue;
      final since = ((library.lastUpdateAt ?? 0) ~/ 1000) - 60;
      final startedAt = DateTime.now().millisecondsSinceEpoch;
      var changed = 0;
      for (final field in ['addedAt', 'updatedAt']) {
        var start = 0;
        while (true) {
          final page = await _request(
            () => source.page(
              library.libraryKey,
              plexType: plexType,
              start: start,
              size: pageSize,
              filters: {'$field>>': '$since'},
            ),
          );
          await db.batch((b) {
            b.insertAllOnConflictUpdate(db.indexTitles, [
              for (final item in page.items)
                if (item['ratingKey'] != null)
                  indexRowFromPlex(
                    item,
                    serverId: library.serverId,
                    serverName: library.serverName,
                    libraryKey: library.libraryKey,
                    libraryTitle: library.title,
                  ),
            ]);
          });
          changed += page.items.length;
          start += page.items.length;
          if (page.items.isEmpty || start >= page.total) break;
        }
      }
      await (db.update(
        db.indexLibraries,
      )..where((l) => l.id.equals(library.id))).write(IndexLibrariesCompanion(lastUpdateAt: Value(startedAt)));
      if (changed > 0) appLogger.i('Library index: ${library.serverName} · ${library.title}: $changed added/changed');
    }
    status.value = status.value.copyWith(phase: LibraryIndexPhase.idle);
  }

  /// Titles per type and library, for Settings and reports.
  Future<({int movies, int shows, int groups, List<IndexedLibrary> libraries})> summary() async {
    final db = await database;
    Future<int> count(String sql) async => (await db.customSelect(sql).getSingle()).read<int>('n');
    return (
      movies: await count("SELECT COUNT(*) AS n FROM index_titles WHERE type = 'movie'"),
      shows: await count("SELECT COUNT(*) AS n FROM index_titles WHERE type = 'show'"),
      groups: await count('SELECT COUNT(DISTINCT group_key) AS n FROM index_titles'),
      libraries: await db.select(db.indexLibraries).get(),
    );
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
