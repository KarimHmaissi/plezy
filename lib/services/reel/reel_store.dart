import 'dart:convert';

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

/// Facts the Reel keeps. Picks, vetoes and the TV's day's pool are small
/// synced settings (newest edit wins between the TV and the phone); events
/// and caches stay in this device's own fork database.
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

  static const String picksKey = 'reel.picks';
  static const String vetoesKey = 'reel.vetoes';

  /// The TV's For You pool for the day, shared with the phone (about 11 KB).
  static const String poolKey = 'reel.pool';

  /// How long a clip asset identity (or a miss) is trusted.
  static const Duration sourceTtl = Duration(days: 30);

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

  // ---- the day's pool (synced) ----

  /// The shared pool as the host wrote it (`{day, entries}`), or null.
  Future<String?> sharedPool() async => (await _settings()).readSetting(poolKey);

  /// The host shares its day's pool. Newest write wins, like picks.
  Future<void> sharePool(String value) async => (await _settings()).writeSetting(poolKey, value);

  // ---- picks (synced) ----

  Future<List<ReelPick>> picks() async {
    final raw = await (await _settings()).readSetting(picksKey);
    if (raw == null) return const [];
    try {
      return [for (final j in jsonDecode(raw) as List) ?ReelPick.fromJson(j)];
    } catch (_) {
      return const [];
    }
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
    final kept = [
      for (final p in await picks())
        if (p.titleId != pick.titleId && p.isFresh(now)) p,
      pick,
    ];
    await (await _settings()).writeSetting(picksKey, jsonEncode([for (final p in kept) p.toJson()]));
    picksChanged.value++;
  }

  Future<void> removePick(String titleId) async {
    final kept = [
      for (final p in await picks())
        if (p.titleId != titleId) p,
    ];
    await (await _settings()).writeSetting(picksKey, jsonEncode([for (final p in kept) p.toJson()]));
    picksChanged.value++;
  }

  // ---- vetoes (synced) ----

  /// `{titleId: {n: notForMeAt ms, k: 'seen'|'kids', s: [asset ids spoiled]}}`.
  Future<Map<String, Map<String, Object?>>> _vetoes() async {
    final raw = await (await _settings()).readSetting(vetoesKey);
    if (raw == null) return {};
    try {
      return {
        for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries)
          if (value is Map) '$key': value.cast<String, Object?>(),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeVetoes(Map<String, Map<String, Object?>> v) async =>
      (await _settings()).writeSetting(vetoesKey, jsonEncode(v));

  Future<void> notForMe(String titleId) async {
    final v = await _vetoes();
    (v[titleId] ??= {})['n'] = _clock().millisecondsSinceEpoch;
    await _writeVetoes(v);
  }

  /// Seen it / For kids: facts, so permanent.
  Future<void> markFact(String titleId, String fact) async {
    final v = await _vetoes();
    (v[titleId] ??= {})['k'] = fact;
    await _writeVetoes(v);
  }

  /// Spoiled me: bans that one asset for good (the title drops to the next rung).
  Future<void> spoiled(String titleId, String assetId) async {
    final v = await _vetoes();
    final entry = v[titleId] ??= {};
    entry['s'] = {...((entry['s'] as List?) ?? const []).map((e) => '$e'), assetId}.toList();
    await _writeVetoes(v);
  }

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

  Future<Set<String>> spoiledAssets(String titleId) async => {
    ...(((await _vetoes())[titleId]?['s'] as List?) ?? const []).map((e) => '$e'),
  };
}
