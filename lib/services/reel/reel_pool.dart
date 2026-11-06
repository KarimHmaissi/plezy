import 'dart:async';
import 'dart:convert';

import '../../utils/app_logger.dart';
import 'reel_decay.dart';
import 'reel_library.dart';
import 'reel_signals.dart';
import 'reel_store.dart';

/// One For You candidate as code assembles it: facts only, no verdicts.
class PoolCandidate {
  const PoolCandidate({
    required this.entry,
    required this.titleId,
    required this.score,
    this.like = const [],
    this.askedFor,
  });

  final String titleId;

  /// A server copy (`serverId` + `ratingKey`).
  final DeckEntry entry;

  /// Similarity to what they love, summed over seeds (code order until the
  /// AI build lands).
  final double score;

  /// The loved titles it is similar to: the why line's possible anchors.
  final List<String> like;

  /// A saved AI ask it came from ("like Lost and Dark").
  final String? askedFor;
}

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

  /// How many days back an earlier pool is still read.
  static const int lookback = 3;

  /// The calendar day of [d], `YYYY-MM-DD`.
  static String dateOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String dayKey(DateTime d) => 'pool:${dateOf(d)}';

  /// Today's day key, by this pool's clock.
  String today() => dayKey(_clock());

  /// Now, by this pool's clock.
  DateTime now() => _clock();

  /// The shared pool: its day (`YYYY-MM-DD`) and rows, or null when there is
  /// none or it can't be read.
  Future<({String day, List<Object?> rows})?> shared() async {
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
        return (day: j['day'] as String, rows: j['entries'] as List<Object?>);
      }
    } catch (_) {}
    return null;
  }

  /// Today's pool if built, else the newest earlier one, else null (the
  /// caller falls back to code order). Each day reads this device's own
  /// pool first, then the shared one. Either way it is the remainder:
  /// titles already gone through in the Reel since that pool's day are
  /// dropped, so a reopen (or the next day, on yesterday's pool) carries on
  /// rather than starting over. Gone through is any recorded event except
  /// [ReelAction.unplayed], which is neutral. Rows written before the pool
  /// kept title ids are returned whole.
  Future<List<DeckEntry>?> cachedPool() async {
    final now = _clock();
    final share = await shared();
    for (var back = 0; back < lookback; back++) {
      final day = now.subtract(Duration(days: back));
      final rows = await _localRows(day) ?? (share != null && share.day == dateOf(day) ? _rows(share.rows) : null);
      if (rows == null) continue;
      final gone = await goneThrough(since: DateTime(day.year, day.month, day.day));
      return [
        for (final r in rows)
          if (r.id == null || !gone.contains(r.id)) r.entry,
      ];
    }
    return null;
  }

  Future<List<({String? id, DeckEntry entry})>?> _localRows(DateTime day) async {
    final raw = await store.cached(dayKey(day));
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      return j is List ? _rows(j) : null;
    } catch (_) {
      return null;
    }
  }

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
          ),
        ),
  ];

  /// The pools' cluster labels (title id → `cl`) over the last [days] days,
  /// this device's own pools and the shared one; a newer day's label wins.
  Future<Map<String, String>> clusters({int days = 30}) async {
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

  /// Whether this device has its own pool for today.
  Future<bool> hasOwnToday() async => await store.cached(dayKey(_clock())) != null;

  /// Whether today's pool is here: this device's own, or the shared one.
  Future<bool> hasToday() async => await hasOwnToday() || (await shared())?.day == dateOf(_clock());

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
  Future<List<DeckEntry>?> build(List<PoolCandidate> candidates, {required String facts}) async {
    final call = model;
    if (call == null || candidates.isEmpty) return null;
    final list = candidates.take(maxCandidates).toList();
    final cards = await library.cards([for (final c in list) c.entry]);
    final byRow = {for (final c in cards) c.best.id: c};
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
    for (final (i, c) in list.indexed) {
      final card = byRow[c.entry.rowId];
      if (card == null) continue;
      final id = 'c${i + 1}';
      idOf[id] = c;
      final fatigue = ReelDecay.fatigue(skips[card.id] ?? const [], now);
      lines.add(
        [
          '$id: ${card.title.title}${card.best.year == null ? '' : ' (${card.best.year})'}',
          card.title.isShow ? 'show' : 'film',
          if (card.facts.genres.isNotEmpty) card.facts.genres.take(3).join('/'),
          card.facts.modelLine(),
          ?card.facts.lengthLine(),
          if (card.title.anime) 'anime',
          if (c.like.isNotEmpty) 'similar to ${c.like.take(3).join(', ')}',
          if (c.askedFor != null) 'from their ask "${c.askedFor}"',
          if (fatigue > 0.05) 'skipped quickly in the Reel lately (fatigue ${fatigue.toStringAsFixed(1)})',
          ...?notes[card.id],
        ].join(' · '),
      );
    }
    if (lines.isEmpty) return null;
    try {
      final input = await call(_system, '$facts\n\nCandidates:\n${lines.join('\n')}', _tool);
      final picked = input?['cards'];
      if (picked is! List) return null;
      final out = <DeckEntry>[];
      final ids = <String>[];
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
          ),
        );
      }
      if (out.isEmpty) return null;
      final rows = [
        for (final (i, e) in out.indexed)
          {'id': ids[i], 'sv': e.serverId, 'rk': e.ratingKey, 'why': ?e.why, 'cl': ?e.cluster},
      ];
      await store.cache(dayKey(now), jsonEncode(rows));
      if (host) {
        try {
          await store.sharePool(jsonEncode({'day': dateOf(now), 'entries': rows}));
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

  /// A why line survives only if it names an anchor from this candidate's
  /// own evidence and is at most 16 words; otherwise the card has none.
  static String? checkedWhy(String? why, String? anchor, PoolCandidate c) {
    final w = why?.trim();
    final a = anchor?.trim();
    if (w == null || w.isEmpty || a == null || a.isEmpty) return null;
    if (w.split(RegExp(r'\s+')).length > 16) return null;
    final evidence = [...c.like, ?c.askedFor].map((e) => e.toLowerCase());
    final la = a.toLowerCase();
    if (!evidence.any((e) => e == la || e.contains(la) || la.contains(e))) return null;
    if (!w.toLowerCase().contains(la)) return null;
    return w;
  }

  static const String _system =
      '''
You build today's For You feed for one household's TV: a feed of trailers and anime openings they flick through like channels. They are choosing what to watch next.
Choose about $target candidates and put them in the order you think they would most enjoy discovering today. You decide the mix of films and shows, the share of anime, and any weekend or weekday tilt, from the facts.
- Ratings are labelled with their source; IMDb with its vote count is the most reliable. Few votes means unproven. "Plex audience (source unknown)" is a weaker signal.
- This is a showcase of the best of their library for them: every card should be worth their evening. Leave out titles the public rates poorly (for example IMDb below about 6 with a fair number of votes), however similar they are to something they liked, unless their own history shows they love exactly that kind of film. Fewer, better cards beat a long list.
- "skipped quickly in the Reel lately" is a fact, not a ban: show such titles sparingly when an equally good fresh one exists.
- Passes (Not for me, "Passed on in the Reel lately") are facts about the kind of title, not bans: a pass on one title never rules out its kind.
- Kids' and family titles only when their own history shows they watch them.
- why: optional, at most 16 words, about why they would like it. It is shown on screen to the household, so write it to them in the second person ("you", "your ask"), never "they" or "their". It must name one anchor from that candidate's evidence ("similar to …" titles or "from their ask …") together with that anchor's real fact. Leave it out when there's nothing honest to say; about half the cards should have none. Never mention ratings, praise words or plot beyond the premise.
- anchor: the exact evidence title or ask your why line names.
- cluster: a 1-3 word label for the kind of title ("space sci-fi", "buddy action", "cosy anime"), the same label for titles of the same kind.''';

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
            },
            'required': ['id', 'cluster'],
          },
        },
      },
      'required': ['cards'],
    },
  };
}
