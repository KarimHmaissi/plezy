import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:plezy_brain/plezy_brain.dart';

import '../../utils/app_logger.dart';
import '../../utils/connectivity_link_type.dart';
import '../comfort/comfort_shows_controller.dart';
import '../companion_remote/host_media_notification.dart' show LocalMediaSession;
import '../companion_remote/phone_mode.dart';
import '../customisation/customisation_store.dart';
import '../history/history_models.dart';
import '../history/history_service.dart';
import '../library_index/index_database.dart';
import '../library_index/library_index.dart';
import '../trackers/trakt/trakt_client.dart';
import 'brain_worker.dart';
import 'history_profiles.dart';
import 'onnx_embedder.dart';
import 'trakt_details_cache.dart';

enum HistoryBrainPhase { idle, syncing, downloading, embedding, failed }

@immutable
class HistoryBrainStatus {
  const HistoryBrainStatus({
    this.phase = HistoryBrainPhase.idle,
    this.profiles = 0,
    this.watched = 0,
    this.vectors = 0,
    this.error,
    this.lastSync,
  });

  final HistoryBrainPhase phase;
  final int profiles;
  final int watched;
  final int vectors;
  final String? error;
  final DateTime? lastSync;

  bool get ready => vectors > 0;

  HistoryBrainStatus copyWith({
    HistoryBrainPhase? phase,
    int? profiles,
    int? watched,
    int? vectors,
    String? error,
    DateTime? lastSync,
  }) => HistoryBrainStatus(
    phase: phase ?? this.phase,
    profiles: profiles ?? this.profiles,
    watched: watched ?? this.watched,
    vectors: vectors ?? this.vectors,
    error: error,
    lastSync: lastSync ?? this.lastSync,
  );
}

/// What one sync did, for logs and reports.
typedef HistoryBrainReport = ({
  int titles,
  int watched,
  int changed,
  int embedded,
  int remaining,
  int traktRequests,
  int dbBytes,
  Duration took,
});

/// Fork: the "watch history brain" on a host (Mac, PC, TV, phone). Turns the
/// merged Plex + Trakt history and the library index into a [BrainStore]
/// of title profiles with embeddings, kept up to date as watches arrive, and
/// answers the AI helper's history questions from it. A phone runs it too,
/// unless it mirrors a TV (see `PhoneMode`).
///
/// Read-only everywhere: Plex is read through the library index and the
/// History page's cache; Trakt only for details of titles not on the
/// servers, ratings and the watchlist.
class HistoryBrain {
  HistoryBrain({Future<Directory> Function()? folder}) : _folder = folder ?? _defaultFolder;

  static final HistoryBrain instance = HistoryBrain();

  final Future<Directory> Function() _folder;
  final ValueNotifier<HistoryBrainStatus> status = ValueNotifier(const HistoryBrainStatus());

  /// A sync runs at most this often unless forced (new watches trigger one).
  static const Duration resyncEvery = Duration(hours: 6);
  static const Duration _historySettle = Duration(seconds: 20);
  static const Duration _extrasEvery = Duration(hours: 12);

  BrainStore? _store;
  Future<OnnxEmbedder>? _embedder;
  Future<HistoryBrainReport?>? _running;
  bool _syncAgain = false;
  Timer? _timer;
  Timer? _debounce;
  List<IndexSource> Function()? _plex;
  TraktClient? Function()? _trakt;
  VoidCallback? _historyListener;
  String? _seenHistory;

  static String? _signature(MergedHistory? h) => h == null
      ? null
      : '${h.plays.length}:${h.plays.firstOrNull?.watchedAt.millisecondsSinceEpoch}:${h.bulk}:${h.matched}';

  static Future<Directory> _defaultFolder() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'brain'));

  Future<BrainStore> get store async {
    if (_store case final s?) return s;
    final dir = await _folder();
    await dir.create(recursive: true);
    return _store = BrainStore.open(p.join(dir.path, 'history_brain.db'));
  }

  Future<OnnxEmbedder> get embedder => _embedder ??= _openEmbedder();

  /// Fork: the brain's own isolate for embedding and vector search (null in
  /// tests, where that work runs here).
  Future<BrainWorker?> get worker => _worker ??= () async {
    await store;
    final dir = await _folder();
    return BrainWorker.spawn(
      dbPath: p.join(dir.path, 'history_brain.db'),
      modelDir: p.join(dir.path, 'models', 'bge-small-en-v1.5'),
    );
  }();
  Future<BrainWorker?>? _worker;

  Future<OnnxEmbedder> _openEmbedder() async {
    try {
      final dir = Directory(p.join((await _folder()).path, 'models', 'bge-small-en-v1.5'));
      status.value = status.value.copyWith(phase: HistoryBrainPhase.downloading);
      // One thread: background indexing stays light on a TV or a laptop,
      // and a single query still takes milliseconds.
      return await OnnxEmbedder.open(dir, threads: 1);
    } catch (_) {
      _embedder = null;
      rethrow;
    }
  }

  /// Start keeping the brain up to date on this host: a sync now (once the
  /// history has loaded), after new watches, and every [resyncEvery]. Safe
  /// to call again (Home calls it each time it starts).
  void start({required List<IndexSource> Function() plex, required TraktClient? Function() trakt}) {
    _plex = plex;
    _trakt = trakt;
    _listen();
    _timer ??= Timer.periodic(resyncEvery, (_) => unawaited(sync()));
    if (_lastSyncAt == null) unawaited(sync());
    _warmTimer ??= Timer(warmAfter, _warm);
  }

  /// Fork: after start-up settles, spawn the brain's isolate and load the
  /// model and vectors, so the first Ask doesn't wait for them. Not while
  /// something plays (tried again later).
  static const Duration warmAfter = Duration(seconds: 30);
  Timer? _warmTimer;

  Future<void> _warm() async {
    if (LocalMediaSession.active.value || !await _modelAllowed()) {
      _warmTimer = Timer(const Duration(minutes: 5), _warm);
      return;
    }
    try {
      final started = DateTime.now();
      await (await worker)?.warm();
      appLogger.d('Brain: warmed in ${DateTime.now().difference(started).inMilliseconds} ms');
    } catch (e) {
      appLogger.d('Brain: warm-up failed', error: e);
    }
  }

  /// Whether the embedding model may be used now: it's already downloaded,
  /// or this device isn't a phone on mobile data only (it's 66 MB).
  Future<bool> _modelAllowed() async {
    if (!PhoneMode.isHandheld) return true;
    final dir = Directory(p.join((await _folder()).path, 'models', 'bge-small-en-v1.5'));
    if (await BgeSmallModel.isDownloaded(dir)) return true;
    try {
      final allowed = !(await Connectivity().checkConnectivity()).isCellularOnly;
      if (!allowed) appLogger.d('Brain: waiting for Wi-Fi to download the model');
      return allowed;
    } catch (_) {
      return true;
    }
  }

  void _listen() {
    final listener = _historyListener;
    if (listener == _onHistoryChanged) return;
    if (listener != null) HistoryService.instance.state.removeListener(listener);
    HistoryService.instance.state.addListener(_historyListener = _onHistoryChanged);
  }

  /// Every load republishes the history, the brain's own included; only new
  /// or changed watches are worth a sync.
  void _onHistoryChanged() {
    final state = HistoryService.instance.state.value;
    if (state.loading) return;
    final signature = _signature(state.history);
    if (signature == _seenHistory) return;
    _seenHistory = signature;
    scheduledSyncs++;
    _debounce?.cancel();
    _debounce = Timer(_historySettle, () => unawaited(sync()));
  }

  /// Syncs the history listener has asked for (tests).
  @visibleForTesting
  int scheduledSyncs = 0;

  /// Tests: listen to the history without starting anything else.
  @visibleForTesting
  void listenForTests() => _listen();

  /// Automatic syncs are at least this far apart.
  static const Duration minSyncGap = Duration(minutes: 1);
  DateTime? _lastSyncAt;

  /// Bring the profiles and vectors up to date. Concurrent calls share one
  /// run (and queue one more if something changed meanwhile). Unless
  /// [force], a sync within [minSyncGap] of the last is skipped.
  Future<HistoryBrainReport?> sync({bool force = false}) {
    _listen();
    if (_running != null) {
      _syncAgain = true;
      return _running!;
    }
    final last = _lastSyncAt;
    final since = last == null ? null : DateTime.now().difference(last);
    if (!force && since != null && since < minSyncGap) {
      // Too soon: run once the gap is up, so a real change isn't lost.
      _debounce?.cancel();
      _debounce = Timer(minSyncGap - since, () => unawaited(sync()));
      return Future.value();
    }
    return _running = _sync().whenComplete(() {
      _running = null;
      _lastSyncAt = DateTime.now();
      if (_syncAgain) {
        _syncAgain = false;
        _debounce?.cancel();
        _debounce = Timer(minSyncGap, () => unawaited(sync()));
      }
    });
  }

  Future<HistoryBrainReport?> _sync() async {
    final plex = _plex;
    if (plex == null) return null;
    final started = DateTime.now();
    status.value = status.value.copyWith(phase: HistoryBrainPhase.syncing);
    try {
      final trakt = _trakt?.call();
      await HistoryService.instance.load(plex: plex, trakt: trakt);
      final history = HistoryService.instance.state.value.history;
      _seenHistory = _signature(history);
      if (history == null) {
        status.value = status.value.copyWith(phase: HistoryBrainPhase.idle);
        return null;
      }
      final store = await this.store;
      final index = await LibraryIndex.instance.database;
      final dir = await _folder();

      final indexPath = (await IndexDatabase.file()).path;
      final plays = history.plays;
      // Grouping tens of thousands of plays against the library: off the
      // app's isolate, like every bulk step below.
      final (:titles, :watched) = await _groupInBackground(indexPath, plays);
      final extras = await _extras(store, trakt);

      // Watched titles that aren't on the servers: details from Trakt.
      final details = TraktDetailsCache(File(p.join(dir.path, 'trakt_details.json')));
      if (trakt != null) {
        await details.fill(trakt, {
          for (final w in watched)
            if (w.ref == null) w.id: w.plays.first,
        });
      }
      final traktDetails = await details.load();

      final rows = await _rows(index, [
        for (final w in watched)
          if (w.ref != null) w.ref!.rowId,
      ]);
      final keep = <String>{};
      final watchedProfiles = [
        for (final w in watched)
          watchedProfile(w, row: rows[w.ref?.rowId], details: traktDetails[w.id], extras: extras),
      ];
      final dbPath = p.join(dir.path, 'history_brain.db');
      var changed = await Isolate.run(_bound(_putProfiles, dbPath, watchedProfiles));
      keep.addAll(watchedProfiles.map((p) => p.id));

      // The rest of the library, a page at a time, only when the library
      // index or the extras changed since last time (most syncs are a new
      // watch: rebuilding 45k unchanged profiles would stall the app).
      final unwatched = [
        for (final r in titles)
          if (!keep.contains(r.titleId)) r.rowId,
      ];
      final stats = await index
          .customSelect('SELECT COUNT(*) AS n, MAX(updated_at) AS u, MAX(added_at) AS a FROM index_titles')
          .getSingle();
      final librarySignature = jsonEncode([
        stats.data['n'],
        stats.data['u'],
        stats.data['a'],
        unwatched.length,
        extras.ratings.length,
        extras.comfort.length,
        extras.watchlist.length,
      ]);
      if (store.meta('library.signature') != librarySignature) {
        for (var i = 0; i < unwatched.length; i += 500) {
          final page = await _rows(index, unwatched.sublist(i, (i + 500).clamp(0, unwatched.length)));
          final rows = page.values.toList();
          final put = await _putLibraryPageInBackground(dbPath, rows, extras);
          changed += put.changed;
          keep.addAll(put.ids);
          // Let the UI and connections breathe between pages.
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        await Isolate.run(_bound(_removeProfilesExcept, dbPath, keep));
        store.setMeta('library.signature', librarySignature);
      }
      _publish(store, HistoryBrainPhase.embedding);

      store.reload();
      final worker = await this.worker;
      final BrainIndexSummary result;
      if (!await _modelAllowed()) {
        // Profiles and history queries work meanwhile; embedding waits for
        // Wi-Fi (the next sync tries again).
        final c = store.counts(TransformerEmbedderIds.bgeSmall);
        result = (embedded: 0, remaining: c.profiles - c.vectors, took: Duration.zero, stopped: true);
      } else if (worker != null) {
        // Embedding runs in the brain's isolate; playback pauses it there.
        worker.reload();
        void onPlayback() => worker.pause(LocalMediaSession.active.value);
        LocalMediaSession.active.addListener(onPlayback);
        onPlayback();
        try {
          result = await worker.index(batchSize: 8, duty: 0.5);
        } finally {
          LocalMediaSession.active.removeListener(onPlayback);
        }
        store.reload();
      } else {
        result = await BrainIndexer(
          store: store,
          embedder: await embedder,
          batchSize: 8,
          // Half the time resting (more when the device is busy): background
          // work, never a pinned CPU or loud fans.
          duty: 0.5,
          shouldPause: () => LocalMediaSession.active.value,
        ).run();
      }
      final counts = store.counts(TransformerEmbedderIds.bgeSmall);
      final dbFile = File(p.join(dir.path, 'history_brain.db'));
      final report = (
        titles: counts.profiles,
        watched: counts.watched,
        changed: changed,
        embedded: result.embedded,
        remaining: result.remaining,
        traktRequests: details.requests + _extrasRequests,
        dbBytes: await dbFile.exists() ? await dbFile.length() : 0,
        took: DateTime.now().difference(started),
      );
      appLogger.i(
        'Brain: ${report.titles} titles (${report.watched} watched), ${report.changed} changed, '
        '${report.embedded} embedded, ${report.remaining} left, ${report.traktRequests} Trakt requests, '
        '${(report.dbBytes / 1e6).toStringAsFixed(1)} MB, ${report.took.inSeconds}s',
      );
      _publish(store, HistoryBrainPhase.idle, lastSync: DateTime.now());
      return report;
    } catch (e, st) {
      appLogger.w('Brain: sync failed', error: e, stackTrace: st);
      status.value = status.value.copyWith(phase: HistoryBrainPhase.failed, error: '$e');
      return null;
    }
  }

  void _publish(BrainStore store, HistoryBrainPhase phase, {DateTime? lastSync}) {
    final counts = store.counts(TransformerEmbedderIds.bgeSmall);
    status.value = status.value.copyWith(
      phase: phase,
      profiles: counts.profiles,
      watched: counts.watched,
      vectors: counts.vectors,
      lastSync: lastSync,
    );
  }

  Future<Map<String, IndexedTitle>> _rows(IndexDatabase db, List<String> ids) async {
    final out = <String, IndexedTitle>{};
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, (i + 500).clamp(0, ids.length));
      for (final t in await (db.select(db.indexTitles)..where((r) => r.id.isIn(chunk))).get()) {
        out[t.id] = t;
      }
    }
    return out;
  }

  int _extrasRequests = 0;

  /// Ratings, watchlist and Comfort shows. Trakt's are fetched every
  /// [_extrasEvery] and kept in the store's meta table between.
  Future<TitleExtras> _extras(BrainStore store, TraktClient? trakt) async {
    _extrasRequests = 0;
    final comfort = <String>{
      for (final s in ComfortShowsController.decodeShows(
        await (await Customisation.store).readSetting(ComfortShowsController.showsCacheKey),
      ))
        ...TitleExtras.keysOf(imdb: s.ids.imdb, tmdb: s.ids.tmdb, tvdb: s.ids.tvdb, trakt: s.ids.trakt),
    };
    var ratings = <String, int>{};
    var watchlist = <String>{};
    final cached = store.meta('trakt.extras');
    final cachedJson = cached == null ? null : jsonDecode(cached) as Map<String, dynamic>;
    final fresh =
        cachedJson != null &&
        DateTime.now().millisecondsSinceEpoch - (cachedJson['at'] as int? ?? 0) < _extrasEvery.inMilliseconds;
    if (cachedJson != null) {
      ratings = (cachedJson['ratings'] as Map).map((k, v) => MapEntry(k as String, v as int));
      watchlist = {...(cachedJson['watchlist'] as List).cast<String>()};
    }
    if (trakt != null && !fresh) {
      try {
        ratings = {};
        for (final type in ['movies', 'shows']) {
          _extrasRequests++;
          for (final r in (await trakt.getRatings(type)).whereType<Map>()) {
            final media = (r['movie'] ?? r['show']) as Map?;
            final ids = (media?['ids'] as Map?) ?? const {};
            final rating = (r['rating'] as num?)?.toInt();
            if (rating == null) continue;
            for (final k in TitleExtras.keysOf(imdb: ids['imdb'] as String?, tmdb: ids['tmdb'], tvdb: ids['tvdb'])) {
              ratings[k] = rating;
            }
          }
        }
        watchlist = {};
        for (var page = 1; page <= 10; page++) {
          _extrasRequests++;
          final res = await trakt.getWatchlist(page: page);
          for (final e in res.items) {
            final ids = e.media?.ids;
            if (ids != null) watchlist.addAll(TitleExtras.keysOf(imdb: ids.imdb, tmdb: ids.tmdb, tvdb: ids.tvdb));
          }
          if (!res.hasMore) break;
        }
        store.setMeta(
          'trakt.extras',
          jsonEncode({
            'at': DateTime.now().millisecondsSinceEpoch,
            'ratings': ratings,
            'watchlist': [...watchlist],
          }),
        );
      } catch (e) {
        appLogger.d('Brain: Trakt ratings or watchlist unavailable', error: e);
      }
    }
    return TitleExtras(ratings: ratings, comfort: comfort, watchlist: watchlist);
  }

  // ── Queries (for the AI helper) ──

  /// Titles whose content is nearest [text] (a plot, a mood, a theme).
  Future<List<({TitleProfile profile, double score})>> searchText(
    String text, {
    int limit = 20,
    bool? watched,
    TitleKind? kind,
    Set<String>? ids,
  }) async {
    final store = await this.store;
    if (!await _modelAllowed()) throw StateError('The similarity model downloads on Wi-Fi; not available yet');
    if (await worker case final w?) {
      return _hits(store, await w.searchText(text, limit: limit, watched: watched, kind: kind, ids: ids));
    }
    final embedder = await this.embedder;
    final query = (await embedder.embed([text], query: true)).single;
    return _hits(store, store.search(embedder.modelId, query, limit: limit, watched: watched, kind: kind, ids: ids));
  }

  /// Titles most like [id].
  Future<List<({TitleProfile profile, double score})>> similar(
    String id, {
    int limit = 20,
    bool? watched,
    TitleKind? kind,
  }) async {
    final store = await this.store;
    if (await worker case final w?) {
      return _hits(store, await w.similar(id, limit: limit, watched: watched, kind: kind));
    }
    return _hits(store, store.similar(TransformerEmbedderIds.bgeSmall, id, limit: limit, watched: watched, kind: kind));
  }

  static List<({TitleProfile profile, double score})> _hits(BrainStore store, List<BrainHit> hits) => [
    for (final h in hits)
      if (store.profile(h.id) case final p?) (profile: p, score: h.score),
  ];

  /// Every watched title's profile.
  Future<List<TitleProfile>> watchedProfiles() async => (await store).profiles(watched: true);

  /// The user's taste for the helper's first prompt ([tasteSummary]), kept
  /// until the next sync (and a day at most) so the prompt stays cached.
  Future<String> taste() async {
    final now = DateTime.now();
    final cached = _taste;
    if (cached != null && cached.syncAt == _lastSyncAt && now.difference(cached.at) < const Duration(days: 1)) {
      return cached.text;
    }
    final text = tasteSummary(await watchedProfiles(), now: now);
    _taste = (text: text, at: now, syncAt: _lastSyncAt);
    return text;
  }

  ({String text, DateTime at, DateTime? syncAt})? _taste;

  Future<TitleProfile?> profile(String id) async => (await store).profile(id);

  void stop() {
    _timer?.cancel();
    _debounce?.cancel();
    _warmTimer?.cancel();
    _timer = _debounce = _warmTimer = null;
    if (_historyListener case final l?) HistoryService.instance.state.removeListener(l);
    _historyListener = null;
  }
}

/// The model ids the store files vectors under.
abstract final class TransformerEmbedderIds {
  static const String bgeSmall = 'bge-small-en-v1.5';
}

// Fork: bulk work, run with Isolate.run (on a connection of its own).
// Closures are made here, at the top level, so they capture only their
// arguments (never the brain and its open database).

R Function() _bound<A, B, R>(R Function(A, B) f, A a, B b) =>
    () => f(a, b);

/// The watched titles, and the library's other titles (one per group).
Future<({List<({String rowId, String titleId})> titles, List<WatchedTitle> watched})> _groupInBackground(
  String indexPath,
  List<HistoryPlay> plays,
) => Isolate.run(() {
  final library = LibraryLookup([
    for (final r in BrainStore.readRows(indexPath, 'SELECT ${LibraryRef.columns} FROM index_titles'))
      LibraryRef.fromRow(r),
  ]);
  final watched = groupWatches(plays, library);
  final watchedGroups = {for (final w in watched) ?w.ref?.groupKey};
  return (
    titles: [
      for (final r in library.titles)
        if (!watchedGroups.contains(r.groupKey)) (rowId: r.rowId, titleId: r.titleId),
    ],
    watched: watched,
  );
});

Future<({int changed, List<String> ids})> _putLibraryPageInBackground(
  String dbPath,
  List<IndexedTitle> rows,
  TitleExtras extras,
) => Isolate.run(() => _putLibraryPage(dbPath, rows, extras));

int _putProfiles(String dbPath, List<TitleProfile> profiles) {
  final store = BrainStore.open(dbPath);
  try {
    return store.putProfiles(profiles);
  } finally {
    store.close();
  }
}

({int changed, List<String> ids}) _putLibraryPage(String dbPath, List<IndexedTitle> rows, TitleExtras extras) {
  final profiles = [for (final row in rows) libraryProfile(row, extras: extras)];
  return (changed: _putProfiles(dbPath, profiles), ids: [for (final p in profiles) p.id]);
}

void _removeProfilesExcept(String dbPath, Set<String> keep) {
  final store = BrainStore.open(dbPath);
  try {
    store.removeProfilesExcept(keep);
  } finally {
    store.close();
  }
}
