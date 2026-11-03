import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'title_profile.dart';

/// A search result: a title id and its similarity (dot product, -1..1).
typedef BrainHit = ({String id, double score});

/// The brain's SQLite file: every [TitleProfile] and its vector.
///
/// Vectors are stored and searched as 8-bit integers with a per-vector
/// scale (a quarter of the size of floats; the ranking barely moves), and
/// searched by brute force in memory, which is fast enough for a home
/// library. A profile whose [TitleProfile.embedText] changed keeps its old
/// vector until [vectorsToUpdate] hands it out again.
class BrainStore {
  BrainStore._(this._db) {
    _db.execute('PRAGMA journal_mode=WAL');
    // Other isolates write to the same file (the app's sync, the indexer).
    _db.execute('PRAGMA busy_timeout=5000');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS profiles (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        watched INTEGER NOT NULL,
        last_watched INTEGER,
        text_hash TEXT NOT NULL,
        data_hash TEXT NOT NULL,
        data TEXT NOT NULL
      )''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS vectors (
        id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        text_hash TEXT NOT NULL,
        scale REAL NOT NULL,
        vec BLOB NOT NULL
      )''');
    _db.execute('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)');
    // What outside sources said about a title (a Wikipedia plot, reviews),
    // fetched once: `data` is the source's JSON, or {"missing": true}.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS enrichment (
        id TEXT NOT NULL,
        source TEXT NOT NULL,
        fetched_at INTEGER NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (id, source)
      )''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_profiles_watched ON profiles (watched)');
  }

  factory BrainStore.open(String path) => BrainStore._(sqlite3.open(path));
  factory BrainStore.memory() => BrainStore._(sqlite3.openInMemory());

  /// Rows of [sql] from another database file, opened read-only (the app's
  /// library index, read from a background isolate).
  static List<Map<String, Object?>> readRows(String path, String sql) {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return [for (final r in db.select(sql)) Map.of(r)];
    } finally {
      db.close();
    }
  }

  final Database _db;

  /// In-memory copy of the vectors for one model, loaded on first search.
  _VectorCache? _cache;

  static String textHash(String text) => sha1.convert(utf8.encode(text)).toString().substring(0, 16);

  /// Add or replace [profiles]; returns how many changed. Unchanged ones
  /// are left alone, so a rebuild touches only what's new.
  int putProfiles(Iterable<TitleProfile> profiles) {
    final existing = _db.prepare('SELECT data_hash FROM profiles WHERE id = ?');
    final upsert = _db.prepare(
      'INSERT INTO profiles (id, kind, watched, last_watched, text_hash, data_hash, data) VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, watched = excluded.watched, '
      'last_watched = excluded.last_watched, text_hash = excluded.text_hash, data_hash = excluded.data_hash, '
      'data = excluded.data',
    );
    var changed = 0;
    _db.execute('BEGIN');
    try {
      for (final p in profiles) {
        final data = jsonEncode(p.toJson());
        final dataHash = textHash(data);
        final current = existing.select([p.id]);
        if (current.isNotEmpty && current.first['data_hash'] == dataHash) continue;
        upsert.execute([
          p.id,
          p.kind.name,
          p.watched ? 1 : 0,
          p.lastWatched?.millisecondsSinceEpoch,
          textHash(p.embedText),
          dataHash,
          data,
        ]);
        changed++;
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      upsert.close();
      existing.close();
    }
    if (changed > 0) _refreshCacheFlags();
    return changed;
  }

  /// Remove profiles not in [keep] (titles gone from history and library).
  int removeProfilesExcept(Set<String> keep) {
    final ids = [for (final r in _db.select('SELECT id FROM profiles')) r['id'] as String];
    final gone = ids.where((id) => !keep.contains(id)).toList();
    if (gone.isEmpty) return 0;
    _db.execute('BEGIN');
    for (final id in gone) {
      _db.execute('DELETE FROM profiles WHERE id = ?', [id]);
      _db.execute('DELETE FROM vectors WHERE id = ?', [id]);
    }
    _db.execute('COMMIT');
    _cache = null;
    return gone.length;
  }

  /// Forget cached vectors and flags (another connection changed the file).
  void reload() => _cache = null;

  Set<String> ids() => {for (final r in _db.select('SELECT id FROM profiles')) r['id'] as String};

  TitleProfile? profile(String id) {
    final rows = _db.select('SELECT data FROM profiles WHERE id = ?', [id]);
    return rows.isEmpty ? null : _decode(rows.first['data'] as String);
  }

  /// Ids of the titles called [title] (any case), watched ones first,
  /// without decoding every profile.
  List<String> idsByTitle(String title) => [
    for (final r in _db.select(
      "SELECT id FROM profiles WHERE lower(json_extract(data, '\$.t')) = ? ORDER BY watched DESC",
      [title.trim().toLowerCase()],
    ))
      r['id'] as String,
  ];

  List<TitleProfile> profiles({bool? watched, Iterable<String>? ids}) {
    if (ids != null) {
      return [
        for (final id in ids)
          if (profile(id) case final p?) p,
      ];
    }
    final rows = watched == null
        ? _db.select('SELECT data FROM profiles')
        : _db.select('SELECT data FROM profiles WHERE watched = ?', [watched ? 1 : 0]);
    return [for (final r in rows) _decode(r['data'] as String)];
  }

  static TitleProfile _decode(String data) => TitleProfile.fromJson((jsonDecode(data) as Map).cast<String, Object?>());

  ({int profiles, int watched, int vectors}) counts(String model) {
    int n(String sql, [List<Object?> args = const []]) => _db.select(sql, args).first.values.first as int;
    return (
      profiles: n('SELECT COUNT(*) FROM profiles'),
      watched: n('SELECT COUNT(*) FROM profiles WHERE watched = 1'),
      vectors: n('SELECT COUNT(*) FROM vectors WHERE model = ?', [model]),
    );
  }

  /// Profiles with no vector from [model], or whose text changed since:
  /// watched titles first (they matter most), then newest watches.
  List<TitleProfile> vectorsToUpdate(String model, {int limit = 64}) {
    final rows = _db.select(
      'SELECT p.data FROM profiles p LEFT JOIN vectors v ON v.id = p.id AND v.model = ? '
      'WHERE v.id IS NULL OR v.text_hash != p.text_hash '
      'ORDER BY p.watched DESC, p.last_watched DESC LIMIT ?',
      [model, limit],
    );
    return [for (final r in rows) _decode(r['data'] as String)];
  }

  /// How many profiles [vectorsToUpdate] would hand out in all.
  int pendingVectors(String model) =>
      _db.select(
            'SELECT COUNT(*) AS n FROM profiles p LEFT JOIN vectors v ON v.id = p.id AND v.model = ? '
            'WHERE v.id IS NULL OR v.text_hash != p.text_hash',
            [model],
          ).first['n']
          as int;

  void putVectors(String model, Map<TitleProfile, Float32List> vectors) {
    final upsert = _db.prepare(
      'INSERT OR REPLACE INTO vectors (id, model, text_hash, scale, vec) VALUES (?, ?, ?, ?, ?)',
    );
    _db.execute('BEGIN');
    try {
      for (final e in vectors.entries) {
        final (scale, q) = quantise(e.value);
        upsert.execute([e.key.id, model, textHash(e.key.embedText), scale, q.buffer.asUint8List()]);
        _cache?.put(e.key.id, scale, q, kind: e.key.kind, watched: e.key.watched);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      upsert.close();
    }
  }

  /// The [limit] titles nearest [query], best first. [watched] and [kind]
  /// narrow it; [ids] limits it to those titles.
  List<BrainHit> search(
    String model,
    Float32List query, {
    int limit = 20,
    bool? watched,
    TitleKind? kind,
    Set<String>? ids,
    Set<String> exclude = const {},
  }) {
    final cache = _vectors(model);
    final hits = <BrainHit>[];
    for (var i = 0; i < cache.ids.length; i++) {
      final id = cache.ids[i];
      if (exclude.contains(id) || (ids != null && !ids.contains(id))) continue;
      if (watched != null && cache.watched[i] != watched) continue;
      if (kind != null && cache.kinds[i] != kind) continue;
      hits.add((id: id, score: cache.score(i, query)));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  /// Titles most like [id] (its own vector as the query).
  List<BrainHit> similar(String model, String id, {int limit = 20, bool? watched, TitleKind? kind}) {
    final cache = _vectors(model);
    final i = cache.index[id];
    if (i == null) return const [];
    return search(model, cache.vector(i), limit: limit, watched: watched, kind: kind, exclude: {id});
  }

  _VectorCache _vectors(String model) {
    final cached = _cache;
    if (cached != null && cached.model == model) return cached;
    final cache = _VectorCache(model);
    for (final r in _db.select(
      'SELECT v.id, v.scale, v.vec, p.kind, p.watched FROM vectors v JOIN profiles p ON p.id = v.id WHERE v.model = ?',
      [model],
    )) {
      cache.put(
        r['id'] as String,
        (r['scale'] as num).toDouble(),
        Int8List.sublistView(r['vec'] as Uint8List),
        kind: r['kind'] == 'show' ? TitleKind.show : TitleKind.movie,
        watched: r['watched'] == 1,
      );
    }
    return _cache = cache;
  }

  /// Watched state changes with every refresh; keep the cache in step.
  void _refreshCacheFlags() {
    final cache = _cache;
    if (cache == null) return;
    for (final r in _db.select('SELECT id, kind, watched FROM profiles')) {
      final i = cache.index[r['id']];
      if (i == null) continue;
      cache.watched[i] = r['watched'] == 1;
      cache.kinds[i] = r['kind'] == 'show' ? TitleKind.show : TitleKind.movie;
    }
  }

  /// Titles [source] has been asked about (found or not).
  Set<String> enrichedIds(String source) => {
    for (final r in _db.select('SELECT id FROM enrichment WHERE source = ?', [source])) r['id'] as String,
  };

  /// What [source] said about [id]; null when not asked or not found.
  Map<String, Object?>? enrichment(String id, String source) {
    final rows = _db.select('SELECT data FROM enrichment WHERE id = ? AND source = ?', [id, source]);
    if (rows.isEmpty) return null;
    final data = (jsonDecode(rows.first['data'] as String) as Map).cast<String, Object?>();
    return data['missing'] == true ? null : data;
  }

  /// Every found [source] entry, by title id.
  Map<String, Map<String, Object?>> enrichments(String source) => {
    for (final r in _db.select('SELECT id, data FROM enrichment WHERE source = ?', [source]))
      if ((jsonDecode(r['data'] as String) as Map).cast<String, Object?>() case final d when d['missing'] != true)
        r['id'] as String: d,
  };

  /// Record what [source] said about [id] (null: it had nothing).
  void putEnrichment(String id, String source, Map<String, Object?>? data) =>
      _db.execute('INSERT OR REPLACE INTO enrichment (id, source, fetched_at, data) VALUES (?, ?, ?, ?)', [
        id,
        source,
        DateTime.now().millisecondsSinceEpoch,
        jsonEncode(data ?? {'missing': true}),
      ]);

  String? meta(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  void setMeta(String key, String? value) => value == null
      ? _db.execute('DELETE FROM meta WHERE key = ?', [key])
      : _db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [key, value]);

  void close() => _db.close();
}

/// [v] as 8-bit integers and the scale that maps them back.
(double, Int8List) quantise(Float32List v) {
  var max = 0.0;
  for (final x in v) {
    if (x.abs() > max) max = x.abs();
  }
  final scale = max == 0 ? 1.0 : max / 127;
  return (scale, Int8List.fromList([for (final x in v) (x / scale).round().clamp(-127, 127)]));
}

class _VectorCache {
  _VectorCache(this.model);
  final String model;
  final ids = <String>[];
  final index = <String, int>{};
  final scales = <double>[];
  final vecs = <Int8List>[];
  final kinds = <TitleKind>[];
  final watched = <bool>[];

  void put(String id, double scale, Int8List v, {TitleKind? kind, bool? watched}) {
    final i = index[id];
    if (i != null) {
      scales[i] = scale;
      vecs[i] = v;
      if (kind != null) kinds[i] = kind;
      if (watched != null) this.watched[i] = watched;
      return;
    }
    index[id] = ids.length;
    ids.add(id);
    scales.add(scale);
    vecs.add(v);
    kinds.add(kind ?? TitleKind.movie);
    this.watched.add(watched ?? false);
  }

  double score(int i, Float32List q) {
    final v = vecs[i];
    var s = 0.0;
    for (var j = 0; j < v.length; j++) {
      s += v[j] * q[j];
    }
    return s * scales[i];
  }

  Float32List vector(int i) {
    final v = vecs[i];
    final out = Float32List(v.length);
    for (var j = 0; j < v.length; j++) {
      out[j] = v[j] * scales[i];
    }
    return out;
  }
}
