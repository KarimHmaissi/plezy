import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import '../ai/facts/seen_state.dart';
import 'reel_decay.dart';
import 'reel_library.dart';
import 'reel_premise.dart';
import 'reel_signals.dart';
import 'reel_store.dart';

/// One For You candidate as code assembles it: facts only, no verdicts.
/// Each source it came from is named in its candidate line.
class PoolCandidate {
  const PoolCandidate({
    required this.entry,
    required this.titleId,
    required this.score,
    this.like = const [],
    this.recent = const [],
    this.saved = const [],
    this.askedFor,
    this.suggested,
    this.added,
  });

  final String titleId;

  /// A server copy (`serverId` + `ratingKey`).
  final DeckEntry entry;

  /// Similarity to its seeds, summed over its sources (code order until the
  /// AI build lands).
  final double score;

  /// The loved titles it is similar to: the why line's possible anchors.
  final List<String> like;

  /// The titles played lately it is similar to (anchors too).
  final List<String> recent;

  /// The Reel Saves it is similar to (anchors too).
  final List<String> saved;

  /// A saved AI ask it came from ("like Lost and Dark").
  final String? askedFor;

  /// An AI suggested list it fills (the AI page's "Suggested for you").
  final String? suggested;

  /// When it reached the servers, for a title added in the last
  /// [newWithin].
  final DateTime? added;

  /// How recent an addition still counts as new.
  static const Duration newWithin = Duration(days: 7);

  /// The anchors a why line may name.
  List<String> get evidence => [...like, ...recent, ...saved, ?askedFor, ?suggested];

  /// This candidate's facts merged with [other]'s (the same title from
  /// another source): scores add, anchors join, the first ask or list
  /// stays.
  PoolCandidate merge(PoolCandidate other) => PoolCandidate(
    entry: entry,
    titleId: titleId,
    score: score + other.score,
    like: _join(like, other.like),
    recent: _join(recent, other.recent),
    saved: _join(saved, other.saved),
    askedFor: askedFor ?? other.askedFor,
    suggested: suggested ?? other.suggested,
    added: added ?? other.added,
  );

  /// The same facts under the card's own copy and title id.
  PoolCandidate onCard(DeckEntry entry, String titleId) => PoolCandidate(
    entry: entry,
    titleId: titleId,
    score: score,
    like: like,
    recent: recent,
    saved: saved,
    askedFor: askedFor,
    suggested: suggested,
    added: added,
  );

  static List<String> _join(List<String> a, List<String> b) =>
      b.isEmpty ? a : [...a, ...b.where((x) => !a.contains(x))];
}

/// The pool the host shares: its day (`YYYY-MM-DD`), rows, "Give it
/// another go" rows (empty when the build gave none), the "What's next
/// after" order and the finished show it is for (null when the build gave
/// none), when it was built (null on a pool shared before builds were
/// stamped) and, when today's build was cleared since
/// ([ReelPool.clearToday]), when.
typedef SharedPool = ({
  String day,
  List<Object?> rows,
  List<Object?> again,
  ({String seed, List<Object?> rows})? next,
  int? at,
  int? cleared,
});

/// What the daily build orders for "What's next after" a finished show
/// (D22): the show they just finished or caught up on ([seed]) and the
/// unseen titles like it ([candidates], facts only).
typedef WhatsNextList = ({ReelCardData seed, List<PoolCandidate> candidates});

/// The model call the daily build makes: system + user text and the tool it
/// must answer with; returns the tool input, or null.
typedef PoolModel = Future<Map<String, dynamic>?> Function(String system, String user, Map<String, Object?> tool);

/// For You's daily pool (spec §7): code gathers about 250 unseen candidates
/// with hard facts only (not Kids, not seen, not resting); one Sonnet call
/// orders about 90 of them, writes optional why lines naming an anchor, and
/// labels clusters. Code then only checks anchors and applies the layout
/// rules. The pool is replaced each day, never added to.
///
/// The [host] (the TV) builds it each day and shares it through the synced
/// settings ([ReelStore.poolKey]); a phone reads that copy and builds its own
/// only once the shared pool is [fallbackAfter] old (or there never was one).
class ReelPool {
  ReelPool({required this.store, required this.library, this.model, this.host = true, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final ReelStore store;
  final ReelLibrary library;
  final PoolModel? model;

  /// This device builds the day's pool and shares it (the TV, a desktop).
  /// A phone is not the host: it builds only as a fallback, and keeps that
  /// build to itself.
  final bool host;
  final DateTime Function() _clock;

  /// What the Reel saw on this device and the other one (the build's facts).
  late final ReelSignals signals = ReelSignals(store: store, host: host, clock: _clock);

  static const int maxCandidates = 250;
  static const int target = 90;

  /// How many days (today included) with no shared pool before a phone
  /// builds its own.
  static const int fallbackAfter = 2;

  /// The calendar day of [d], `YYYY-MM-DD` ([ReelStore.dayStamp]): the day in
  /// day keys and in the shared pool.
  static String dateOf(DateTime d) => ReelStore.dayStamp(d);

  /// Read for [ReelStore.daysKept] days at most, and for cluster labels
  /// ([clusters]) for [ReelStore.poolsKept]; the daily sweep deletes older
  /// ones.
  static String dayKey(DateTime d) => 'pool:${dateOf(d)}';

  /// The day's "Give it another go" order (the same build's `another_go`).
  /// Read for [ReelStore.daysKept] days at most; the daily sweep deletes
  /// older ones.
  static String againKey(DateTime d) => 'again:${dateOf(d)}';

  /// At most this many started-and-left shows go to the daily build.
  static const int maxAgain = 40;

  /// The day's "What's next after" order (the same build's `whats_next`),
  /// with the finished show it is for. Read for [ReelStore.daysKept] days at
  /// most; the daily sweep deletes older ones.
  static String nextKey(DateTime d) => 'next:${dateOf(d)}';

  /// At most this many titles like the finished show go to the daily build.
  static const int maxNext = 40;

  /// Today's day key, by this pool's clock.
  String today() => dayKey(_clock());

  /// Now, by this pool's clock.
  DateTime now() => _clock();

  /// The shared pool, or null when there is none or it can't be read.
  Future<SharedPool?> shared() async {
    final String? raw;
    try {
      raw = await store.sharedPool();
    } catch (e) {
      appLogger.d('Reel: shared pool unavailable', error: e);
      return null;
    }
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      if (j is Map && j['day'] is String && j['entries'] is List) {
        return (
          day: j['day'] as String,
          rows: j['entries'] as List<Object?>,
          again: j['again'] is List ? j['again'] as List<Object?> : const <Object?>[],
          next: _sharedNext(j['next']),
          at: j['at'] is int ? j['at'] as int : null,
          cleared: j['cleared'] is int ? j['cleared'] as int : null,
        );
      }
    } catch (_) {}
    return null;
  }

  static ({String seed, List<Object?> rows})? _sharedNext(Object? j) =>
      j is Map && j['seed'] is String && j['rows'] is List
      ? (seed: j['seed'] as String, rows: j['rows'] as List<Object?>)
      : null;

  /// Today's pool if built, else the newest earlier one, else null (the
  /// caller falls back to code order). Each day reads this device's own
  /// pool first, then the shared one. Either way it is the remainder:
  /// titles already gone through in the Reel since that pool's day are
  /// dropped, so a reopen (or the next day, on yesterday's pool) carries on
  /// rather than starting over. Gone through is any recorded event except
  /// [ReelAction.unplayed], which is neutral. Rows written before the pool
  /// kept title ids are returned whole.
  Future<List<DeckEntry>?> cachedPool() => _remainder(dayKey, (share) => share.rows);

  /// The "Give it another go" order from today's build, else the newest
  /// earlier one, as its remainder, like [cachedPool]; null when no build
  /// gave one (the deck falls back to code order).
  Future<List<DeckEntry>?> cachedAgain() => _remainder(againKey, (share) => share.again.isEmpty ? null : share.again);

  /// The "What's next after" order a build gave for the finished show
  /// [seedId], from today's build, else the newest earlier one, as its
  /// remainder, like [cachedPool]; null when no build ordered that show
  /// (the deck falls back to code order). An order kept for another show
  /// is never read for this one.
  Future<List<DeckEntry>?> cachedNext(String seedId) =>
      _remainder(nextKey, (share) => share.next?.seed == seedId ? share.next!.rows : null, seed: seedId);

  /// [seed]: the rows are kept with the finished show they are for
  /// ([nextKey]), and only that show's are read.
  Future<List<DeckEntry>?> _remainder(
    String Function(DateTime day) key,
    List<Object?>? Function(SharedPool share) sharedRows, {
    String? seed,
  }) async {
    final now = _clock();
    final share = await shared();
    await _honourClear(share);
    for (var back = 0; back < ReelStore.daysKept; back++) {
      final day = now.subtract(Duration(days: back));
      final rows =
          await _localRows(day, key: key, seed: seed) ??
          (share != null && share.day == dateOf(day) ? _rowsOrNull(sharedRows(share)) : null);
      if (rows == null) continue;
      final gone = await goneThrough(since: DateTime(day.year, day.month, day.day));
      return [
        for (final r in rows)
          if (r.id == null || !gone.contains(r.id)) r.entry,
      ];
    }
    return null;
  }

  Future<List<({String? id, DeckEntry entry})>?> _localRows(
    DateTime day, {
    String Function(DateTime) key = dayKey,
    String? seed,
  }) async {
    final raw = await store.cached(key(day));
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      if (seed != null) return j is Map && j['seed'] == seed && j['rows'] is List ? _rows(j['rows'] as List) : null;
      return j is List ? _rows(j) : null;
    } catch (_) {
      return null;
    }
  }

  static List<({String? id, DeckEntry entry})>? _rowsOrNull(List<Object?>? list) => list == null ? null : _rows(list);

  static List<({String? id, DeckEntry entry})> _rows(List<Object?> list) => [
    for (final j in list)
      if (j is Map && j['sv'] is String && j['rk'] is String)
        (
          id: j['id'] is String ? j['id'] as String : null,
          entry: DeckEntry(
            serverId: j['sv'] as String,
            ratingKey: j['rk'] as String,
            why: j['why'] is String ? j['why'] as String : null,
            cluster: j['cl'] is String ? j['cl'] as String : null,
            hook: j['hk'] is String ? j['hk'] as String : null,
          ),
        ),
  ];

  /// The pools' cluster labels (title id → `cl`) over the last [days] days,
  /// this device's own pools and the shared one; a newer day's label wins.
  Future<Map<String, String>> clusters({int days = ReelStore.poolsKept}) async {
    final now = _clock();
    final share = await shared();
    final out = <String, String>{};
    void add(Iterable<({String? id, DeckEntry entry})> rows) {
      for (final r in rows) {
        final id = r.id, cl = r.entry.cluster;
        if (id != null && cl != null) out.putIfAbsent(id, () => cl);
      }
    }

    for (var back = 0; back < days; back++) {
      final day = now.subtract(Duration(days: back));
      add(await _localRows(day) ?? const []);
      if (share != null && share.day == dateOf(day)) add(_rows(share.rows));
    }
    return out;
  }

  /// Titles with a recorded Reel event (other than unplayed) since [since].
  Future<Set<String>> goneThrough({required DateTime since}) async => {
    for (final e in await store.events(since: since))
      if (e.action != ReelAction.unplayed.name) e.titleId,
  };

  /// Whether this device has its own pool for today (one built before a
  /// clear on the other device doesn't count; see [clearToday]).
  Future<bool> hasOwnToday() async {
    await _honourClear(await shared());
    return await store.cached(dayKey(_clock())) != null;
  }

  /// Whether today's pool is here: this device's own, or the shared one
  /// (unless today's build was cleared since it was shared).
  Future<bool> hasToday() async {
    if (await hasOwnToday()) return true;
    final share = await shared();
    return share != null && share.day == dateOf(_clock()) && share.cleared == null;
  }

  /// Bumped when [clearToday] runs on this device, so a live For You builds
  /// again (a clear on the other device arrives as a synced change).
  static final ValueNotifier<int> clears = ValueNotifier(0);

  /// "Rebuild today's For You": today's build is dropped, so the next build
  /// reads the facts (their note among them) as they are now. This device's
  /// own pool and "Give it another go" order for today go. A shared pool for
  /// today stays as the stopgap but is marked cleared: the TV drops its own
  /// copy of today and builds again, and a phone waits for that build
  /// rather than spending a call of its own. Until the new build lands,
  /// For You reads the newest earlier pool's remainder. Returns whether
  /// this device does the rebuild ([shouldBuild]); false on a phone whose
  /// TV builds.
  Future<bool> clearToday() async {
    final now = _clock();
    await store.uncache(dayKey(now));
    await store.uncache(againKey(now));
    await store.uncache(nextKey(now));
    try {
      final raw = await store.sharedPool();
      final j = raw == null ? null : jsonDecode(raw);
      if (j is Map && j['day'] == dateOf(now)) {
        await store.sharePool(jsonEncode({...j, 'cleared': now.millisecondsSinceEpoch}));
      }
    } catch (e) {
      appLogger.w('Reel: clearing the shared pool failed', error: e);
    }
    appLogger.i("[ReelDeck] for-you: today's build cleared");
    clears.value++;
    return shouldBuild();
  }

  /// A clear on the other device reaches this one through [share]: this
  /// device's own pool and order for today, when built before that clear,
  /// are dropped.
  Future<void> _honourClear(SharedPool? share) async {
    final cleared = share?.cleared;
    final now = _clock();
    if (share == null || cleared == null || share.day != dateOf(now)) return;
    for (final key in [dayKey(now), againKey(now), nextKey(now)]) {
      final at = await store.cachedAt(key);
      if (at != null && at.millisecondsSinceEpoch <= cleared) await store.uncache(key);
    }
  }

  /// Whether this device should run today's build: nothing for today yet,
  /// and either it is the [host], or the shared pool is [fallbackAfter]
  /// days old (or there never was one), so the host isn't building.
  Future<bool> shouldBuild() async {
    if (await hasToday()) return false;
    if (host) return true;
    final day = (await shared())?.day;
    if (day == null) return true;
    final now = _clock();
    for (var back = 0; back < fallbackAfter; back++) {
      if (day == dateOf(now.subtract(Duration(days: back)))) return false;
    }
    return true;
  }

  /// Code order: the candidates by similarity with fatigue applied.
  Future<List<DeckEntry>> codeOrder(List<PoolCandidate> candidates) async {
    final skips = await store.quickSkips();
    final now = _clock();
    final scored = [
      for (final c in candidates)
        (c: c, s: ReelDecay.effective(c.score, ReelDecay.fatigue(skips[c.titleId] ?? const [], now))),
    ]..sort((a, b) => b.s.compareTo(a.s));
    return [for (final x in scored) x.c.entry];
  }

  /// Builds today's pool from [candidates] (already filtered to unseen,
  /// not resting, not Kids) and caches it; the [host] also shares it.
  /// Returns null when there is no model or the call failed, leaving
  /// yesterday's pool in place.
  ///
  /// [again] are the shows they started and left ([anotherGoCandidates]):
  /// the same call orders them in its optional `another_go` array, for the
  /// "Give it another go" deck, with no call of its own. When the call
  /// gives none, that deck keeps its code order.
  ///
  /// [next] is the show they just finished and the unseen titles like it
  /// (D22): the same call orders them in its optional `whats_next` array,
  /// for the "What's next after" deck, again with no call of its own.
  Future<List<DeckEntry>?> build(
    List<PoolCandidate> candidates, {
    required String facts,
    List<PoolCandidate> again = const [],
    WhatsNextList? next,
  }) async {
    final call = model;
    if (call == null || candidates.isEmpty) return null;
    final list = candidates.take(maxCandidates).toList();
    final againList = again.take(maxAgain).toList();
    final nextList = (next?.candidates ?? const <PoolCandidate>[]).take(maxNext).toList();
    final now = _clock();
    final (:lines, :idOf, :byRow, :hasPremise) = await _candidateLines(
      list,
      also: [for (final c in againList) c.entry, for (final c in nextList) c.entry],
    );
    if (lines.isEmpty) return null;
    final againLines = <String>[];
    final againOf = <String, ReelCardData>{};
    for (final (i, c) in againList.indexed) {
      final card = byRow[c.entry.rowId];
      if (card == null) continue;
      final id = 'g${i + 1}';
      againOf[id] = card;
      againLines.add(againLine(id, card));
    }
    final nextLines = <String>[];
    final nextOf = <String, ReelCardData>{};
    for (final (i, c) in nextList.indexed) {
      final card = byRow[c.entry.rowId];
      if (card == null) continue;
      final id = 'n${i + 1}';
      nextOf[id] = card;
      nextLines.add(nextLine(id, card));
    }
    final user = StringBuffer('$facts\n\nCandidates:\n${lines.join('\n')}');
    if (againLines.isNotEmpty) {
      user.write(
        '\n\nAnother go (shows they started and left, for the "Give it another go" deck only; '
        'never For You cards):\n${againLines.join('\n')}',
      );
    }
    final seed = next?.seed;
    if (seed != null && nextLines.isNotEmpty) {
      final s = seed.facts.seen;
      user.write(
        "\n\nWhat's next (they just finished ${seed.title.title}"
        '${seed.best.year == null ? '' : ' (${seed.best.year})'}, ${s.line()}; unseen titles like it, '
        'for the "What\'s next after" deck only; never For You cards):\n${nextLines.join('\n')}',
      );
    }
    try {
      final input = await call(systemPrompt('about $target'), user.toString(), _tool);
      await _keepAgain(input?['another_go'], againOf, now);
      if (seed != null) await _keepNext(input?['whats_next'], nextOf, seed.id, now);
      final (:out, :ids) = _picked(input?['cards'], idOf, byRow, hasPremise);
      if (out.isEmpty) return null;
      final rows = [
        for (final (i, e) in out.indexed)
          {'id': ids[i], 'sv': e.serverId, 'rk': e.ratingKey, 'why': ?e.why, 'cl': ?e.cluster, 'hk': ?e.hook},
      ];
      await store.cache(dayKey(now), jsonEncode(rows));
      if (host) {
        try {
          final againRows = await _againRows(now);
          final nextRows = await _nextRows(now);
          await store.sharePool(
            jsonEncode({
              'day': dateOf(now),
              'at': now.millisecondsSinceEpoch,
              'entries': rows,
              'again': ?againRows,
              'next': ?nextRows,
            }),
          );
        } catch (e) {
          appLogger.w('Reel: sharing the pool failed', error: e);
        }
      }
      return out;
    } catch (e) {
      appLogger.w('Reel: daily build failed', error: e);
      return null;
    }
  }

  /// The candidate lines both calls send (the daily build and More like
  /// this), with what reading the answer needs: each line's candidate by
  /// its `c` id, the cards by row, and the ids that had a premise to write
  /// a hook from. [also] are read with the same batch (the build's "Another
  /// go" shows).
  Future<
    ({List<String> lines, Map<String, PoolCandidate> idOf, Map<String, ReelCardData> byRow, Set<String> hasPremise})
  >
  _candidateLines(List<PoolCandidate> list, {List<DeckEntry> also = const []}) async {
    final cards = await library.cards([for (final c in list) c.entry, ...also]);
    final byRow = <String, ReelCardData>{for (final c in cards) c.best.id: c};
    final skips = await signals.quickSkips();
    final now = _clock();
    final notes = ReelSignals.notes(
      await signals.since(now.subtract(const Duration(days: 30))),
      {for (final c in cards) c.id},
      picks: {for (final p in await store.picks()) p.titleId: p.at},
      now: now,
    );
    final lines = <String>[];
    final idOf = <String, PoolCandidate>{};
    final hasPremise = <String>{};
    for (final (i, c) in list.indexed) {
      final card = byRow[c.entry.rowId];
      if (card == null) continue;
      final id = 'c${i + 1}';
      idOf[id] = c;
      final fatigue = ReelDecay.fatigue(skips[card.id] ?? const [], now);
      final premise = ReelPremise.source(tagline: card.best.tagline, summary: card.best.summary);
      if (premise != null) hasPremise.add(id);
      lines.add(
        [
          '$id: ${card.title.title}${card.best.year == null ? '' : ' (${card.best.year})'}',
          card.title.isShow ? 'show' : 'film',
          if (card.facts.genres.isNotEmpty) card.facts.genres.take(3).join('/'),
          card.facts.modelLine(),
          ?card.facts.lengthLine(),
          if (card.title.anime) 'anime',
          if (c.like.isNotEmpty) 'similar to ${c.like.take(3).join(', ')}',
          if (c.recent.isNotEmpty) 'similar to recent plays ${c.recent.take(3).join(', ')}',
          if (c.saved.isNotEmpty) 'similar to Reel Saves ${c.saved.take(3).join(', ')}',
          if (c.askedFor != null) 'from their ask "${c.askedFor}"',
          if (c.suggested != null) 'from the suggested list "${c.suggested}"',
          ?addedLine(c.added, now),
          if (fatigue > 0.05) 'skipped quickly in the Reel lately (fatigue ${fatigue.toStringAsFixed(1)})',
          ...?notes[card.id],
          if (premise != null) 'premise: $premise',
        ].join(' · '),
      );
    }
    return (lines: lines, idOf: idOf, byRow: byRow, hasPremise: hasPremise);
  }

  /// The answer's `cards` as entries, known `c` ids only and each once, with
  /// checked why and hook lines; [ids] are their cards' title ids.
  static ({List<DeckEntry> out, List<String> ids}) _picked(
    Object? picked,
    Map<String, PoolCandidate> idOf,
    Map<String, ReelCardData> byRow,
    Set<String> hasPremise,
  ) {
    final out = <DeckEntry>[];
    final ids = <String>[];
    if (picked is! List) return (out: out, ids: ids);
    final used = <String>{};
    for (final p in picked) {
      if (p is! Map) continue;
      final c = idOf['${p['id']}'];
      if (c == null || !used.add('${p['id']}')) continue;
      ids.add(byRow[c.entry.rowId]!.id);
      out.add(
        DeckEntry(
          serverId: c.entry.serverId,
          ratingKey: c.entry.ratingKey,
          why: checkedWhy(p['why'] as String?, p['anchor'] as String?, c),
          cluster: (p['cluster'] as String?)?.trim().toLowerCase(),
          hook: ReelPremise.checkedHook(
            p['hook'] is String ? p['hook'] as String : null,
            hadSource: hasPremise.contains('${p['id']}'),
          ),
        ),
      );
    }
    return (out: out, ids: ids);
  }

  /// More like this (V2-39): the fewest and most cards one press inserts.
  static const int moreLikeMin = 6;
  static const int moreLikeMax = 8;

  /// Titles like the seed read from the brain for one press.
  static const int moreLikeCandidates = 40;

  /// More like this (V2-39): one call with the daily build's prompt over
  /// [candidates] (titles like [seed], the seed as each one's `like`
  /// anchor), asking for the [moreLikeMin] to [moreLikeMax] they would most
  /// enjoy next. Returns them in the call's order, at most [moreLikeMax],
  /// with checked why and hook lines; null when there is no model, no
  /// candidate or the call failed. Nothing is cached or shared: the cards
  /// are for this session only. [call] stands in for [model].
  Future<List<DeckEntry>?> moreLike(
    String seed,
    List<PoolCandidate> candidates, {
    required String facts,
    PoolModel? call,
  }) async {
    final ask = call ?? model;
    if (ask == null || candidates.isEmpty) return null;
    final (:lines, :idOf, :byRow, :hasPremise) = await _candidateLines(candidates.take(moreLikeCandidates).toList());
    if (lines.isEmpty) return null;
    final user =
        '$facts\n\n'
        'More like this: in the Reel, on the card for $seed, they asked for more like it. '
        "This is not today's feed: choose the $moreLikeMin to $moreLikeMax candidates below they would most enjoy "
        'next, in order. Every other rule holds. There is no "Another go" list.\n\n'
        'Candidates:\n${lines.join('\n')}';
    try {
      final input = await ask(systemPrompt('$moreLikeMin to $moreLikeMax'), user, _tool);
      final (:out, ids: _) = _picked(input?['cards'], idOf, byRow, hasPremise);
      return out.isEmpty ? null : out.take(moreLikeMax).toList();
    } catch (e) {
      appLogger.w('Reel: More like this call failed', error: e);
      return null;
    }
  }

  /// One "Another go" line: the show, its facts (the seen line says how far
  /// they got) and when they last watched it.
  static String againLine(String id, ReelCardData card) {
    final last = card.facts.seen.last;
    return [
      '$id: ${card.title.title}${card.best.year == null ? '' : ' (${card.best.year})'}',
      'show',
      if (card.facts.genres.isNotEmpty) card.facts.genres.take(3).join('/'),
      card.facts.modelLine(),
      ?card.facts.lengthLine(),
      if (card.title.anime) 'anime',
      if (last != null) 'last watched ${SeenState.monthName(last.month)} ${last.year}',
    ].join(' · ');
  }

  /// Keeps the call's `another_go` order (known `g` ids only, each once)
  /// as today's [againKey]; nothing is kept when it gave none.
  Future<void> _keepAgain(Object? ids, Map<String, ReelCardData> againOf, DateTime now) async {
    if (ids is! List) return;
    final used = <String>{};
    final rows = [
      for (final id in ids)
        if (againOf['$id'] case final card? when used.add('$id'))
          {'id': card.id, 'sv': card.best.serverId, 'rk': card.best.ratingKey},
    ];
    if (rows.isEmpty) return;
    await store.cache(againKey(now), jsonEncode(rows));
  }

  /// One "What's next" line: the title and its facts, as the build reads
  /// any candidate (no anchors: the finished show is in the list's heading).
  static String nextLine(String id, ReelCardData card) {
    final premise = ReelPremise.source(tagline: card.best.tagline, summary: card.best.summary);
    return [
      '$id: ${card.title.title}${card.best.year == null ? '' : ' (${card.best.year})'}',
      card.title.isShow ? 'show' : 'film',
      if (card.facts.genres.isNotEmpty) card.facts.genres.take(3).join('/'),
      card.facts.modelLine(),
      ?card.facts.lengthLine(),
      if (card.title.anime) 'anime',
      if (premise != null) 'premise: $premise',
    ].join(' · ');
  }

  /// Keeps the call's `whats_next` order (known `n` ids only, each once)
  /// as today's [nextKey], with the finished show [seedId] it is for;
  /// nothing is kept when it gave none.
  Future<void> _keepNext(Object? ids, Map<String, ReelCardData> nextOf, String seedId, DateTime now) async {
    if (ids is! List) return;
    final used = <String>{};
    final rows = [
      for (final id in ids)
        if (nextOf['$id'] case final card? when used.add('$id'))
          {'id': card.id, 'sv': card.best.serverId, 'rk': card.best.ratingKey},
    ];
    if (rows.isEmpty) return;
    await store.cache(nextKey(now), jsonEncode({'seed': seedId, 'rows': rows}));
    appLogger.i('[ReelNext] build ordered ${rows.length} of ${nextOf.length} for $seedId');
  }

  /// Today's kept `whats_next` order, for the shared pool; null when none.
  Future<Map<String, Object?>?> _nextRows(DateTime now) async {
    final raw = await store.cached(nextKey(now));
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      return j is Map && j['seed'] is String && j['rows'] is List && (j['rows'] as List).isNotEmpty
          ? {'seed': j['seed'], 'rows': j['rows']}
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Today's kept `another_go` rows, for the shared pool; null when none.
  Future<List<Object?>?> _againRows(DateTime now) async {
    final raw = await store.cached(againKey(now));
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      return j is List && j.isNotEmpty ? j : null;
    } catch (_) {
      return null;
    }
  }

  /// The candidate line's tag for a title added in the last
  /// [PoolCandidate.newWithin], else null.
  static String? addedLine(DateTime? added, DateTime now) {
    if (added == null) return null;
    // Calendar days; rounded, so a clock change doesn't shift the count.
    final days =
        (DateTime(now.year, now.month, now.day).difference(DateTime(added.year, added.month, added.day)).inHours / 24)
            .round();
    if (days < 0 || days >= PoolCandidate.newWithin.inDays) return null;
    return switch (days) {
      0 => 'added to the library today',
      1 => 'added to the library yesterday',
      _ => 'added to the library $days days ago',
    };
  }

  /// A why line survives only if it names an anchor from this candidate's
  /// own evidence and is at most 16 words; otherwise the card has none.
  static String? checkedWhy(String? why, String? anchor, PoolCandidate c) {
    final w = why?.trim();
    final a = anchor?.trim();
    if (w == null || w.isEmpty || a == null || a.isEmpty) return null;
    if (w.split(RegExp(r'\s+')).length > 16) return null;
    final evidence = c.evidence.map((e) => e.toLowerCase());
    final la = a.toLowerCase();
    if (!evidence.any((e) => e == la || e.contains(la) || la.contains(e))) return null;
    if (!w.toLowerCase().contains(la)) return null;
    return w;
  }

  /// The prompt both calls use; [count] is how many candidates to choose
  /// ("about 90" for the daily build).
  static String systemPrompt(String count) =>
      '''
You build today's For You feed for one household's TV: a feed of trailers and anime openings they flick through like channels. They are choosing what to watch next.
Choose $count candidates and put them in the order you think they would most enjoy discovering today. You decide the mix of films and shows, the share of anime, and any weekend or weekday tilt, from the facts.
- Ratings are labelled with their source; IMDb with its vote count is the most reliable. Few votes means unproven. "Plex audience (source unknown)" is a weaker signal.
- This is a showcase of the best of their library for them: every card should be worth their evening. Leave out titles the public rates poorly (for example IMDb below about 6 with a fair number of votes), however similar they are to something they liked, unless their own history shows they love exactly that kind of film. Fewer, better cards beat a long list.
- Candidates come from several places, each named in its line: similar to titles they love, similar to what they played lately, similar to their Reel Saves, their saved asks, the AI page's suggested lists, and titles added to the library this week. These are facts about where a title came from, not a ranking.
- "skipped quickly in the Reel lately" is a fact, not a ban: show such titles sparingly when an equally good fresh one exists.
- Passes (Not for me, "Passed on in the Reel lately") are facts about the kind of title, not bans: a pass on one title never rules out its kind.
- Kids' and family titles only when their own history shows they watch them.
- "In their own words", when the facts have it, is the household's own note to you about this feed. Where it disagrees with the defaults above (the rating bar, the mix, kids' titles, how often a skipped or passed-on kind comes back), follow their note. It never changes the rules for why, anchor, cluster, hook, another_go and whats_next below.
- why: optional, at most 16 words, about why they would like it. It is shown on screen to the household, so write it to them in the second person ("you", "your ask"), never "they" or "their". It must name one anchor from that candidate's evidence (a "similar to …" title, "similar to recent plays …" or "similar to Reel Saves …" title, "from their ask …" or "from the suggested list …") together with that anchor's real fact. Leave it out when there's nothing honest to say; about half the cards should have none. Never mention ratings, praise words or plot beyond the premise.
- anchor: the exact evidence title, ask or list your why line names.
- cluster: a 1-3 word label for the kind of title ("space sci-fi", "buddy action", "cosy anime"), the same label for titles of the same kind.
- hook: optional, at most ${ReelPremise.hookWords} words: what the title is about, for someone deciding whether to watch it. Write it only from that candidate's own "premise:" text, never from memory, and leave it out when the candidate has none. It is shown on screen, so it must not spoil: only the opening setup, never a twist, a death, an ending or who did it. No ratings or praise words.
- another_go: optional, only when there is an "Another go" list. Those are shows they started and left: "sampled" (an episode or two, long ago) or "paused" (not watched for two to six months). Give the ids (g1, g2, …) of the ones worth another go today, in the order you would offer them, and leave out any their history says they gave up on for good. They are a separate deck: never put a g id in cards.
- whats_next: optional, only when there is a "What's next" list. They just finished or caught up on the show named in its heading; the list is unseen titles like it. Give the ids (n1, n2, …) of the ones worth watching next, in the order you would offer them, leaving out any that aren't worth their evening. They are a separate deck: never put an n id in cards or another_go.''';

  static const Map<String, Object?> _tool = {
    'name': 'reel_pool',
    'description': "Today's For You feed, in order.",
    'input_schema': {
      'type': 'object',
      'properties': {
        'cards': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string', 'description': 'Candidate id, e.g. c12'},
              'why': {'type': 'string'},
              'anchor': {'type': 'string'},
              'cluster': {'type': 'string'},
              'hook': {
                'type': 'string',
                'description': 'At most ${ReelPremise.hookWords} words, from the candidate premise only; no spoilers',
              },
            },
            'required': ['id', 'cluster'],
          },
        },
        'another_go': {
          'type': 'array',
          'description': 'Ids from the "Another go" list (e.g. g3), in the order to offer them; optional',
          'items': {'type': 'string'},
        },
        'whats_next': {
          'type': 'array',
          'description': 'Ids from the "What\'s next" list (e.g. n2), in the order to offer them; optional',
          'items': {'type': 'string'},
        },
      },
      'required': ['cards'],
    },
  };
}
