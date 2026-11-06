import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../database/fork_database.dart';
import '../customisation/customisation_store.dart';
import 'reel_decay.dart';

/// What the Reel records (spec §7). Scrolling past records nothing.
enum ReelAction {
  sampled,
  quickSkip,
  toEnd,
  replay,
  unmute,
  watch,
  watchOnTv,
  save,
  notForMe,
  spoiled,
  seenIt,
  forKids,

  /// Opened the title's own page from its card.
  details,

  /// Left before its clip showed a first frame, or after the clip failed.
  /// Neutral: it adds no fatigue and is not a sample.
  unplayed,
}

/// What one daily [ReelStore.sweep] deleted: old pool rows, `deck:` and
/// `cursor:` rows, expired `src:` rows, and old events.
typedef ReelSweep = ({int pools, int days, int sources, int events});

/// One saved pick, waiting on the TV's Home for 3 days.
class ReelPick {
  const ReelPick({
    required this.titleId,
    required this.groupKey,
    required this.serverId,
    required this.ratingKey,
    required this.title,
    required this.at,
    this.deck,
  });

  final String titleId;
  final String groupKey;
  final String serverId;
  final String ratingKey;
  final String title;
  final DateTime at;
  final String? deck;

  static const Duration fresh = Duration(days: 3);
  static const int maxShown = 3;

  bool isFresh(DateTime now) => now.difference(at) < fresh;

  Map<String, Object?> toJson() => {
    'id': titleId,
    'g': groupKey,
    'sv': serverId,
    'rk': ratingKey,
    't': title,
    'at': at.millisecondsSinceEpoch,
    'deck': ?deck,
  };

  static ReelPick? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], g = j['g'], sv = j['sv'], rk = j['rk'], at = j['at'];
    if (id is! String || g is! String || sv is! String || rk is! String || at is! int) return null;
    return ReelPick(
      titleId: id,
      groupKey: g,
      serverId: sv,
      ratingKey: rk,
      title: j['t'] as String? ?? '',
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      deck: j['deck'] as String?,
    );
  }
}

/// Facts the Reel keeps. Picks and vetoes are small synced settings, one per
/// title (`reel.pick.<titleId>`, `reel.veto.<titleId>`), so catch-up merges
/// them title by title and the newest edit of each title wins between the TV
/// and the phone. Events and caches stay in this device's own fork database.
class ReelStore {
  ReelStore({
    Future<ForkDatabase> Function()? database,
    Future<CustomisationStore> Function()? settings,
    DateTime Function()? clock,
  }) : _database = database ?? (() => Customisation.localDatabase),
       _settings = settings ?? (() => Customisation.store),
       _clock = clock ?? DateTime.now;

  static final ReelStore instance = ReelStore();

  final Future<ForkDatabase> Function() _database;
  final Future<CustomisationStore> Function() _settings;
  final DateTime Function() _clock;

  /// One saved pick per title: a [ReelPick] as JSON.
  static const String pickKeyPrefix = 'reel.pick.';

  /// One veto per title: `{n: notForMeAt ms, k: 'seen'|'kids', s: [asset ids spoiled]}`.
  static const String vetoKeyPrefix = 'reel.veto.';

  static String pickKey(String titleId) => '$pickKeyPrefix$titleId';
  static String vetoKey(String titleId) => '$vetoKeyPrefix$titleId';

  /// The old format: every pick (or every veto) in one setting, so one
  /// device's write replaced the other's whole set on catch-up. Still read
  /// for one release: each new copy is moved into the per-title keys once.
  /// TODO(reel): stop reading these one release after per-title keys ship.
  static const String picksKey = 'reel.picks';
  static const String vetoesKey = 'reel.vetoes';

  /// This device only (see [SyncUnits.syncsSetting]): a digest of the old
  /// setting last moved into per-title keys here, so a pick removed since
  /// isn't brought back from it.
  static const String picksMigratedKey = 'reel.migrated.picks';
  static const String vetoesMigratedKey = 'reel.migrated.vetoes';

  /// How long a clip asset identity (or a miss) is trusted.
  static const Duration sourceTtl = Duration(days: 30);

  /// Day-scoped cache rows (`pool:<day>`, `deck:…:<day>`, `cursor:…:<day>`)
  /// are read for today and the 2 days before at most (ReelPool.cachedPool);
  /// the daily [sweep] deletes older ones.
  static const int daysKept = 3;

  /// The cache row holding the day ([dayStamp]) the sweep last ran on.
  static const String sweptKey = 'sweep:day';

  /// `yyyy-mm-dd` from [d]'s own date fields: the day in day-scoped keys.
  static String dayStamp(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Bumped when the picks change, so the Home row reloads.
  static final ValueNotifier<int> picksChanged = ValueNotifier(0);

  // ---- events (this device only) ----

  Future<void> record(String titleId, ReelAction action, {String deck = '', int? seconds}) async {
    final db = await _database();
    await db
        .into(db.reelEvents)
        .insert(
          ReelEventsCompanion.insert(
            titleId: titleId,
            action: action.name,
            deck: Value(deck),
            at: _clock().millisecondsSinceEpoch,
            seconds: Value(seconds),
          ),
        );
  }

  /// Quick skips per title within the fatigue window (older ones weigh
  /// almost nothing: 0.5^(120/14) < 0.003).
  Future<Map<String, List<DateTime>>> quickSkips({Duration within = const Duration(days: 120)}) async {
    final db = await _database();
    final since = _clock().subtract(within).millisecondsSinceEpoch;
    final rows = await (db.select(
      db.reelEvents,
    )..where((e) => e.action.equals(ReelAction.quickSkip.name) & e.at.isBiggerOrEqualValue(since))).get();
    final out = <String, List<DateTime>>{};
    for (final r in rows) {
      (out[r.titleId] ??= []).add(DateTime.fromMillisecondsSinceEpoch(r.at, isUtc: true));
    }
    return out;
  }

  Future<double> fatigueOf(String titleId) async =>
      ReelDecay.fatigue((await quickSkips())[titleId] ?? const [], _clock());

  /// Events since [since], for the facts block the AI build reads.
  Future<List<ReelEventRecord>> events({required DateTime since}) async {
    final db = await _database();
    return (db.select(db.reelEvents)
          ..where((e) => e.at.isBiggerOrEqualValue(since.millisecondsSinceEpoch))
          ..orderBy([(e) => OrderingTerm.asc(e.at)]))
        .get();
  }

  /// Keeps the log small: events older than [keep] are dropped.
  Future<int> prune({Duration keep = const Duration(days: 400)}) async {
    final db = await _database();
    final before = _clock().subtract(keep).millisecondsSinceEpoch;
    return (db.delete(db.reelEvents)..where((e) => e.at.isSmallerThanValue(before))).go();
  }

  // ---- caches (this device only) ----

  Future<String?> cached(String key, {Duration? ttl}) async {
    final db = await _database();
    final row = await (db.select(db.reelCache)..where((c) => c.key.equals(key))).getSingleOrNull();
    if (row == null) return null;
    if (ttl != null && _clock().millisecondsSinceEpoch - row.updatedAt > ttl.inMilliseconds) return null;
    return row.value;
  }

  Future<void> cache(String key, String value) async {
    final db = await _database();
    await db
        .into(db.reelCache)
        .insertOnConflictUpdate(
          ReelCacheCompanion.insert(key: key, value: value, updatedAt: _clock().millisecondsSinceEpoch),
        );
  }

  // ---- housekeeping (this device only) ----

  Future<ReelSweep?>? _sweeping;

  /// The daily sweep, at most once per day on this device: pool rows older
  /// than [daysKept] days, `deck:` and `cursor:` rows not written for
  /// [daysKept] days, `src:` rows past [sourceTtl], and old events
  /// ([prune]). Returns what it deleted, or null when it already ran today.
  /// Calls made while one runs share it.
  Future<ReelSweep?> sweep() => _sweeping ??= _sweep().whenComplete(() => _sweeping = null);

  Future<ReelSweep?> _sweep() async {
    final now = _clock();
    final today = dayStamp(now);
    if (await cached(sweptKey) == today) return null;
    final db = await _database();
    final nowMs = now.millisecondsSinceEpoch;
    // Pool keys sort by day, so everything from `pool:` up to the oldest
    // day still read is older.
    final oldestPool = 'pool:${dayStamp(now.subtract(const Duration(days: daysKept - 1)))}';
    final pools = await (db.delete(
      db.reelCache,
    )..where((c) => c.key.isBiggerOrEqualValue('pool:') & c.key.isSmallerThanValue(oldestPool))).go();
    final dayRowsBefore = nowMs - const Duration(days: daysKept).inMilliseconds;
    final days =
        await (db.delete(db.reelCache)..where(
              (c) => (c.key.like('deck:%') | c.key.like('cursor:%')) & c.updatedAt.isSmallerThanValue(dayRowsBefore),
            ))
            .go();
    final sources = await (db.delete(
      db.reelCache,
    )..where((c) => c.key.like('src:%') & c.updatedAt.isSmallerThanValue(nowMs - sourceTtl.inMilliseconds))).go();
    final events = await prune();
    await cache(sweptKey, today);
    return (pools: pools, days: days, sources: sources, events: events);
  }

  // ---- old one-setting format (read for one release) ----

  /// The old setting's last raw value and its digest, per old key, so
  /// repeat reads skip hashing it.
  final Map<String, ({String raw, String digest})> _digests = {};
  final Map<String, Future<void>> _moving = {};

  String _digest(String oldKey, String raw) {
    final last = _digests[oldKey];
    if (last != null && last.raw == raw) return last.digest;
    final digest = sha1.convert(utf8.encode(raw)).toString();
    _digests[oldKey] = (raw: raw, digest: digest);
    return digest;
  }

  /// The entries of the old setting [oldKey] not yet moved into per-title
  /// keys, by title id; empty once moved. On this device's own data it moves
  /// them now ([move]) and returns empty. A phone mirroring its TV leaves
  /// that to the TV and reads them as they are.
  Future<Map<String, T>> _unmoved<T>(
    CustomisationStore settings, {
    required String oldKey,
    required String markerKey,
    required Map<String, T> Function(String raw) decode,
    required Future<void> Function(Map<String, T> entries) move,
  }) async {
    final raw = await settings.readSetting(oldKey);
    if (raw == null) return const {};
    final digest = _digest(oldKey, raw);
    if (await settings.readSetting(markerKey) == digest) return const {};
    final entries = _tryDecode(decode, raw);
    if (settings is! LocalCustomisationStore) return entries;
    // Reads made together move it once.
    final run = _moving.putIfAbsent(oldKey, () => _move(() => move(entries), settings, markerKey, digest));
    try {
      await run;
    } finally {
      // Already awaited above.
      unawaited(_moving.remove(oldKey));
    }
    return const {};
  }

  static Map<String, T> _tryDecode<T>(Map<String, T> Function(String raw) decode, String raw) {
    try {
      return decode(raw);
    } catch (_) {
      return const {};
    }
  }

  static Future<void> _move(
    Future<void> Function() move,
    CustomisationStore settings,
    String markerKey,
    String digest,
  ) async {
    await move();
    await settings.writeSetting(markerKey, digest);
  }

  static Map<String, ReelPick> _decodeOldPicks(String raw) => {
    for (final p in (jsonDecode(raw) as List).map(ReelPick.fromJson).nonNulls) p.titleId: p,
  };

  static Map<String, Map<String, Object?>> _decodeOldVetoes(String raw) => {
    for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries)
      if (value is Map) '$key': value.cast<String, Object?>(),
  };

  Future<Map<String, ReelPick>> _oldPicks(CustomisationStore settings) => _unmoved(
    settings,
    oldKey: picksKey,
    markerKey: picksMigratedKey,
    decode: _decodeOldPicks,
    move: (old) async {
      final now = _clock();
      for (final p in old.values) {
        if (!p.isFresh(now)) continue;
        final have = _decodePick(await settings.readSetting(pickKey(p.titleId)));
        if (have != null && !p.at.isAfter(have.at)) continue;
        await settings.writeSetting(pickKey(p.titleId), jsonEncode(p.toJson()));
      }
    },
  );

  Future<Map<String, Map<String, Object?>>> _oldVetoes(CustomisationStore settings) => _unmoved(
    settings,
    oldKey: vetoesKey,
    markerKey: vetoesMigratedKey,
    decode: _decodeOldVetoes,
    move: (old) async {
      for (final MapEntry(key: titleId, value: v) in old.entries) {
        final have = _decodeVeto(await settings.readSetting(vetoKey(titleId)));
        final merged = _mergeVeto(have, v);
        if (have != null && jsonEncode(merged) == jsonEncode(have)) continue;
        await settings.writeSetting(vetoKey(titleId), jsonEncode(merged));
      }
    },
  );

  /// One title's veto with [other] folded in: the later Not for me, either
  /// fact, and every spoiled asset.
  static Map<String, Object?> _mergeVeto(Map<String, Object?>? mine, Map<String, Object?> other) {
    final out = {...?mine};
    final n = [out['n'], other['n']].whereType<int>();
    if (n.isNotEmpty) out['n'] = n.reduce((a, b) => a > b ? a : b);
    out['k'] ??= other['k'];
    final s = {..._assets(out['s']), ..._assets(other['s'])};
    if (s.isNotEmpty) out['s'] = s.toList();
    return out;
  }

  static Iterable<String> _assets(Object? s) => ((s as List?) ?? const []).map((e) => '$e');

  // ---- picks (synced) ----

  static ReelPick? _decodePick(String? raw) {
    if (raw == null) return null;
    try {
      return ReelPick.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<List<ReelPick>> picks() async {
    final settings = await _settings();
    final old = await _oldPicks(settings);
    final byTitle = {
      ...old,
      for (final p in (await settings.readSettingsWithPrefix(pickKeyPrefix)).values.map(_decodePick).nonNulls)
        p.titleId: p,
    };
    return byTitle.values.toList();
  }

  /// The picks the Home row shows: fresh ones, newest first, at most 3.
  Future<List<ReelPick>> freshPicks() async {
    final now = _clock();
    final all = (await picks()).where((p) => p.isFresh(now)).toList()..sort((a, b) => b.at.compareTo(a.at));
    return all.take(ReelPick.maxShown).toList();
  }

  /// Saves [pick] (replacing an earlier save of the same title) and prunes
  /// stale ones. One action, one decision: the watchlist mirror is the
  /// caller's.
  Future<void> savePick(ReelPick pick) async {
    final now = _clock();
    final settings = await _settings();
    final stale = [
      for (final p in await picks())
        if (p.titleId != pick.titleId && !p.isFresh(now)) p.titleId,
    ];
    await settings.writeSetting(pickKey(pick.titleId), jsonEncode(pick.toJson()));
    for (final id in stale) {
      await settings.writeSetting(pickKey(id), null);
    }
    picksChanged.value++;
  }

  Future<void> removePick(String titleId) async {
    final settings = await _settings();
    await _oldPicks(settings);
    await settings.writeSetting(pickKey(titleId), null);
    picksChanged.value++;
  }

  // ---- vetoes (synced) ----

  static Map<String, Object?>? _decodeVeto(String? raw) {
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map ? v.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  /// Every title's veto, by title id.
  Future<Map<String, Map<String, Object?>>> _vetoes() async {
    final settings = await _settings();
    final old = await _oldVetoes(settings);
    final mine = {
      for (final MapEntry(:key, :value) in (await settings.readSettingsWithPrefix(vetoKeyPrefix)).entries)
        key.substring(vetoKeyPrefix.length): ?_decodeVeto(value),
    };
    return {
      for (final id in {...old.keys, ...mine.keys}) id: old[id] == null ? mine[id]! : _mergeVeto(mine[id], old[id]!),
    };
  }

  /// One title's veto (empty when it has none).
  Future<Map<String, Object?>> _veto(String titleId) async {
    final settings = await _settings();
    final old = await _oldVetoes(settings);
    final mine = _decodeVeto(await settings.readSetting(vetoKey(titleId)));
    final o = old[titleId];
    return o == null ? {...?mine} : _mergeVeto(mine, o);
  }

  Future<void> _editVeto(String titleId, void Function(Map<String, Object?> v) edit) async {
    final v = await _veto(titleId);
    edit(v);
    await (await _settings()).writeSetting(vetoKey(titleId), jsonEncode(v));
  }

  Future<void> notForMe(String titleId) => _editVeto(titleId, (v) => v['n'] = _clock().millisecondsSinceEpoch);

  /// Seen it / For kids: facts, so permanent.
  Future<void> markFact(String titleId, String fact) => _editVeto(titleId, (v) => v['k'] = fact);

  /// Spoiled me: bans that one asset for good (the title drops to the next rung).
  Future<void> spoiled(String titleId, String assetId) =>
      _editVeto(titleId, (v) => v['s'] = {..._assets(v['s']), assetId}.toList());

  /// Titles code-built pools leave out today: resting after Not for me, or
  /// marked seen / for kids.
  Future<Set<String>> excluded() async {
    final now = _clock();
    return {
      for (final MapEntry(:key, :value) in (await _vetoes()).entries)
        if (value['k'] != null ||
            ReelDecay.resting(
              value['n'] is int ? DateTime.fromMillisecondsSinceEpoch(value['n'] as int, isUtc: true) : null,
              now,
            ))
          key,
    };
  }

  Future<Set<String>> spoiledAssets(String titleId) async => {..._assets((await _veto(titleId))['s'])};
}
