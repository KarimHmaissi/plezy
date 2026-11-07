import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../database/fork_database.dart';
import '../customisation/customisation_store.dart';
import 'reel_decay.dart';
import 'reel_deck_prefs.dart';

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

  /// Asked for more like this title from its card (V2-39).
  moreLikeThis,

  /// Left before its clip showed a first frame, or after the clip failed.
  /// Neutral: it adds no fatigue and is not a sample.
  unplayed,
}

/// What one daily [ReelStore.sweep] deleted: old pool rows (`pool:`,
/// `again:`, `week:`, `person:` and `next:`), `deck:` and `cursor:` rows, expired `src:` rows, old `meta:`
/// rows, and old events.
typedef ReelSweep = ({int pools, int days, int sources, int metas, int events});

/// One saved pick. It stays saved until it is removed ([ReelStore.removePick]):
/// the saved list ([ReelStore.savedPicks]) has no expiry and no cap. Only
/// Tonight's picks ([ReelStore.freshPicks]) look at the last [fresh] days.
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

  /// Tonight's picks: Saves from the last 3 days, at most 3 (the card is
  /// laid out for three posters). Not a limit on the saved list.
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
/// and the phone. The TV's day's pool, the For You note and each device's
/// signals are synced settings too (newest edit wins). Events and caches stay
/// in this device's own fork database.
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

  /// The TV's For You pool for the day, shared with the phone (about 11 KB).
  static const String poolKey = 'reel.pool';

  /// The household's own words to For You's daily build (free text; either
  /// device writes it).
  static const String forYouNoteKey = 'reel.forYouNote';

  /// How long a clip asset identity (or a miss) is trusted.
  static const Duration sourceTtl = Duration(days: 30);

  /// How long a card's own lean metadata row (`meta:`, ReelMetadata) is
  /// kept. It is shown fresh for 7 days and kept longer only as the
  /// fallback when a read fails; the daily [sweep] deletes older ones.
  static const Duration metadataKept = Duration(days: 30);

  /// Day-scoped cache rows (`pool:<day>`, `again:<day>`, `next:<day>`, `deck:…:<day>`,
  /// `cursor:…:<day>`) are read for today and the 2 days before at most
  /// (ReelPool.cachedPool); the daily [sweep] deletes older ones, except
  /// `pool:` rows (see [poolsKept]).
  static const int daysKept = 3;

  /// `pool:<day>` rows are kept this many days: the daily build's cluster
  /// labels for the Reel's signals (ReelPool.clusters, V2-36) look back as
  /// far as its 30-day facts. About 11 KB a day.
  static const int poolsKept = 30;

  /// `week:<first day>` rows (New this week, D22) are kept this many days
  /// after their week began: this week's and last week's.
  static const int weeksKept = 14;

  /// `person:<day>` rows (the Person deck, D22) are kept this many days:
  /// the deck's rotation remembers who it featured that long
  /// (ReelPool.personRest).
  static const int personsKept = 14;

  /// The card a deck's next cold start opens at once (V2-04, ReelHead):
  /// one row per deck on this device, swept with the day rows once it hasn't
  /// been written for [daysKept] days.
  static String headKey(String deckId) => 'head:$deckId';

  /// Where the cursor was in [deckId] on [day] (V2-14, ReelCursor): written
  /// on every card change, read when the deck's list next loads. Swept with
  /// the day rows once it hasn't been written for [daysKept] days.
  static String cursorKey(String deckId, DateTime day) => 'cursor:$deckId:${dayStamp(day)}';

  /// A deck's list kept for [day] (V2-14): For You's code order, so a
  /// later load skips the gather. Swept with the day rows.
  static String deckKey(String deckId, DateTime day) => 'deck:$deckId:${dayStamp(day)}';

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

  /// Whether this device recorded anything in the Reel since [since] (any
  /// action, [ReelAction.unplayed] included: the Reel was opened). One row
  /// read at most.
  Future<bool> usedSince(DateTime since) async {
    final db = await _database();
    final row =
        await (db.select(db.reelEvents)
              ..where((e) => e.at.isBiggerOrEqualValue(since.millisecondsSinceEpoch))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
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

  /// [cached] for many keys in a few reads: key → value for the keys
  /// that have a row (within [ttl]).
  Future<Map<String, String>> cachedMany(Iterable<String> keys, {Duration? ttl}) async {
    final list = keys.toSet().toList();
    if (list.isEmpty) return const {};
    final db = await _database();
    final now = _clock().millisecondsSinceEpoch;
    final out = <String, String>{};
    for (var i = 0; i < list.length; i += 400) {
      final chunk = list.sublist(i, i + 400 > list.length ? list.length : i + 400);
      for (final row in await (db.select(db.reelCache)..where((c) => c.key.isIn(chunk))).get()) {
        if (ttl != null && now - row.updatedAt > ttl.inMilliseconds) continue;
        out[row.key] = row.value;
      }
    }
    return out;
  }

  /// When [key]'s cache row was last written, or null when there is none.
  Future<DateTime?> cachedAt(String key) async {
    final db = await _database();
    final row = await (db.select(db.reelCache)..where((c) => c.key.equals(key))).getSingleOrNull();
    return row == null ? null : DateTime.fromMillisecondsSinceEpoch(row.updatedAt);
  }

  /// Rewrites [key]'s cache row with [transform] of its value, in one
  /// transaction, keeping its `updatedAt`: a lead-in learned for a clip
  /// (V2-23) never extends the clip identity's 30-day trust. A missing row,
  /// or a [transform] that returns null, writes nothing. Returns whether it
  /// wrote.
  Future<bool> patchCached(String key, String? Function(String value) transform) async {
    final db = await _database();
    return db.transaction(() async {
      final row = await (db.select(db.reelCache)..where((c) => c.key.equals(key))).getSingleOrNull();
      if (row == null) return false;
      final next = transform(row.value);
      if (next == null || next == row.value) return false;
      await (db.update(db.reelCache)..where((c) => c.key.equals(key))).write(ReelCacheCompanion(value: Value(next)));
      return true;
    });
  }

  /// Drops [key]'s cache row.
  Future<void> uncache(String key) async {
    final db = await _database();
    await (db.delete(db.reelCache)..where((c) => c.key.equals(key))).go();
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

  /// The daily sweep, at most once per day on this device: `pool:` rows
  /// older than [poolsKept] days, `again:` and `next:` rows older than
  /// [daysKept] days, `week:` rows whose week began more than [weeksKept]
  /// days ago, `person:` rows older than [personsKept] days,
  /// `deck:` and `cursor:` rows not written for [daysKept] days, `src:` rows
  /// past [sourceTtl], `head:` rows not written for [daysKept] days,
  /// `meta:` rows not written for [metadataKept], and old
  /// events ([prune]). Returns what it deleted, or null when it already ran
  /// today. Calls made while one runs share it.
  Future<ReelSweep?> sweep() => _sweeping ??= _sweep().whenComplete(() => _sweeping = null);

  Future<ReelSweep?> _sweep() async {
    final now = _clock();
    final today = dayStamp(now);
    if (await cached(sweptKey) == today) return null;
    final db = await _database();
    final nowMs = now.millisecondsSinceEpoch;
    // Day keys sort by day, so everything from `<prefix>` up to the oldest
    // day still read is older.
    Future<int> olderThan(String prefix, int days) {
      final oldest = '$prefix${dayStamp(now.subtract(Duration(days: days - 1)))}';
      return (db.delete(
        db.reelCache,
      )..where((c) => c.key.isBiggerOrEqualValue(prefix) & c.key.isSmallerThanValue(oldest))).go();
    }

    final pools =
        await olderThan('pool:', poolsKept) +
        await olderThan('again:', daysKept) +
        await olderThan('week:', weeksKept) +
        await olderThan('person:', personsKept) +
        await olderThan('next:', daysKept);
    final dayRowsBefore = nowMs - const Duration(days: daysKept).inMilliseconds;
    final days =
        await (db.delete(db.reelCache)..where(
              (c) =>
                  (c.key.like('deck:%') | c.key.like('cursor:%') | c.key.like('head:%')) &
                  c.updatedAt.isSmallerThanValue(dayRowsBefore),
            ))
            .go();
    final sources = await (db.delete(
      db.reelCache,
    )..where((c) => c.key.like('src:%') & c.updatedAt.isSmallerThanValue(nowMs - sourceTtl.inMilliseconds))).go();
    final metas = await (db.delete(
      db.reelCache,
    )..where((c) => c.key.like('meta:%') & c.updatedAt.isSmallerThanValue(nowMs - metadataKept.inMilliseconds))).go();
    final events = await prune();
    await cache(sweptKey, today);
    return (pools: pools, days: days, sources: sources, metas: metas, events: events);
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
    // A read that saw no marker may get here just after another read's move
    // finished: that copy is already moved.
    if (await settings.readSetting(markerKey) == digest) return;
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
      // A title removed after it was saved (here, or on the other device and
      // synced here) stays removed: the old copy only brings back a later save.
      final stamps = settings is LocalCustomisationStore
          ? await settings.readSyncStamps()
          : const <String, SyncStamp>{};
      for (final p in old.values) {
        final gone = stamps[SyncUnits.setting(pickKey(p.titleId))];
        if (gone != null && gone.deleted && gone.stamp >= p.at.millisecondsSinceEpoch) continue;
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

  // ---- the day's pool (synced) ----

  /// The shared pool as the host wrote it (`{day, entries}`), or null.
  Future<String?> sharedPool() async => (await _settings()).readSetting(poolKey);

  /// The host shares its day's pool. Newest write wins, like picks.
  Future<void> sharePool(String value) async => (await _settings()).writeSetting(poolKey, value);

  // ---- For You in their own words (synced) ----

  /// Their note to For You, trimmed; null when there is none.
  Future<String?> forYouNote() async {
    final note = (await (await _settings()).readSetting(forYouNoteKey))?.trim();
    return note == null || note.isEmpty ? null : note;
  }

  /// Keeps [note] (trimmed) as their note to For You; empty or null removes
  /// it. Newest edit wins between the TV and the phone.
  Future<void> setForYouNote(String? note) async {
    final n = note?.trim();
    await (await _settings()).writeSetting(forYouNoteKey, n == null || n.isEmpty ? null : n);
  }

  // ---- per-device Reel signals (synced; see ReelSignals) ----

  Future<String?> readSignals(String key) async => (await _settings()).readSetting(key);

  Future<void> writeSignals(String key, String value) async => (await _settings()).writeSetting(key, value);

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

  /// Every saved pick, newest first: the saved list ("From the Reel" on
  /// Home, Android TV's Play Next). No expiry and no cap; a Save stays
  /// until it is removed.
  Future<List<ReelPick>> savedPicks() async => (await picks())..sort((a, b) => b.at.compareTo(a.at));

  /// Tonight's picks (the decision card): the Saves of the last
  /// [ReelPick.fresh], newest first, at most [ReelPick.maxShown].
  Future<List<ReelPick>> freshPicks() async {
    final now = _clock();
    final all = (await picks()).where((p) => p.isFresh(now)).toList()..sort((a, b) => b.at.compareTo(a.at));
    return all.take(ReelPick.maxShown).toList();
  }

  /// Saves [pick] (replacing an earlier save of the same title). Every
  /// other Save is left as it is: nothing is pruned. One action, one
  /// decision: the watchlist mirror is the caller's.
  Future<void> savePick(ReelPick pick) async {
    final settings = await _settings();
    await settings.writeSetting(pickKey(pick.titleId), jsonEncode(pick.toJson()));
    picksChanged.value++;
  }

  Future<void> removePick(String titleId) async {
    final settings = await _settings();
    await _oldPicks(settings);
    await settings.writeSetting(pickKey(titleId), null);
    picksChanged.value++;
  }

  /// Removes the Saves of the copy [serverId] / [ratingKey] (the item a
  /// "From the Reel" card on Home shows). False: none was saved.
  Future<bool> removeSavedCopy({required String serverId, required String ratingKey}) async {
    final ids = [
      for (final p in await picks())
        if (p.serverId == serverId && p.ratingKey == ratingKey) p.titleId,
    ];
    if (ids.isEmpty) return false;
    final settings = await _settings();
    for (final id in ids) {
      await settings.writeSetting(pickKey(id), null);
    }
    picksChanged.value++;
    return true;
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

  /// Titles passed on with Not for me (on either device), and when: the
  /// daily build's "passed on lately" facts.
  Future<Map<String, DateTime>> passedOn() async => {
    for (final MapEntry(:key, :value) in (await _vetoes()).entries)
      if (value['n'] case final int ms) key: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
  };

  Future<Set<String>> spoiledAssets(String titleId) async => {..._assets((await _veto(titleId))['s'])};

  // ---- deck order, hidden decks and start deck (synced; V2-52) ----

  /// Bumped when this device writes the deck prefs, so a playing Reel and
  /// the Decks screen take the change up.
  static final ValueNotifier<int> deckPrefsChanged = ValueNotifier(0);

  Future<ReelDeckPrefs> deckPrefs() async {
    final s = await _settings();
    return ReelDeckPrefs.decode(
      await s.readSetting(ReelDeckPrefs.decksKey),
      await s.readSetting(ReelDeckPrefs.startKey),
    );
  }

  /// Writes the parts of [next] that differ from [was] (each key syncs as
  /// its own unit, so an untouched one keeps its stamp).
  Future<void> writeDeckPrefs(ReelDeckPrefs next, {required ReelDeckPrefs was}) async {
    final s = await _settings();
    if (next.encodeDecks() != was.encodeDecks()) await s.writeSetting(ReelDeckPrefs.decksKey, next.encodeDecks());
    if (next.start != was.start) await s.writeSetting(ReelDeckPrefs.startKey, next.start.name);
    deckPrefsChanged.value++;
  }

  // ---- the last deck (this device only) ----

  static const String _lastDeckKey = 'lastDeck';

  /// The deck this device was last on, for the "Where I left off" start.
  Future<String?> lastDeck() => cached(_lastDeckKey);

  Future<void> rememberDeck(String id) => cache(_lastDeckKey, id);
}
