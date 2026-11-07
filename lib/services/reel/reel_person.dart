import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:plezy_brain/plezy_brain.dart' show TitleProfile;

import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import '../brain/history_brain.dart';
import 'reel_decks.dart';
import 'reel_library.dart';
import 'reel_pool.dart';
import 'reel_store.dart';

/// One person in the brain's watch history (D22): their name, the role
/// they had in more of the titles watched, how many titles with them have
/// a real (dated) watch, and the newest such watch.
@immutable
class PersonStat {
  const PersonStat({required this.name, required this.role, required this.titles, this.last});

  final String name;
  final PersonRole role;
  final int titles;
  final DateTime? last;
}

/// The Person deck's rules (D22, build plan §3 "A person you love").
///
/// Who counts: directors and cast of the titles they have watched, from
/// the brain. A title counts for a person only with a real watch (a dated
/// play; imports and "mark as watched" don't count), once per title
/// however often it was watched, and only for its directors and its first
/// [castNames] cast names (the cast cap). A person qualifies with at
/// least [minWatched] such titles.
///
/// Who is chosen: one person a day, rotating. The qualifying people rank
/// by titles watched, then the newest watch, then name. The day's person
/// is the first in that rank not featured in the last
/// [ReelPool.personRest] days; when everyone qualifying was, the one
/// featured longest ago. A person needs at least [minUnseen] unseen titles
/// on the servers (not Kids-only, not resting after Not for me), else the
/// next one is tried, at most [tries] people. Once chosen, the person
/// stays for the day (the day's `person:` row), so every load and both
/// devices show the same one.
abstract final class ReelPerson {
  /// Cast names per title that count (billing order).
  static const int castNames = 3;

  /// Titles with a real watch a person needs to qualify.
  static const int minWatched = 3;

  /// Unseen titles on the servers a person needs for a deck.
  static const int minUnseen = 3;

  /// People tried for a day before the deck stays empty.
  static const int tries = 8;

  /// At most this many index rows are read for one person.
  static const int rowsRead = 600;

  /// The qualifying people in [watched], ranked (see [ReelPerson]).
  static List<PersonStat> rank(Iterable<TitleProfile> watched) {
    final names = <String, String>{};
    final directed = <String, int>{};
    final starred = <String, int>{};
    final titles = <String, int>{};
    final last = <String, DateTime>{};
    for (final p in watched) {
      final seen = p.lastWatched;
      if (seen == null) continue;
      // Each name once per title, by its lower case; the first spelling met
      // names them.
      Set<String> keys(Iterable<String> list) {
        final out = <String>{};
        for (final raw in list) {
          final name = raw.trim();
          if (name.isEmpty) continue;
          final key = name.toLowerCase();
          names.putIfAbsent(key, () => name);
          out.add(key);
        }
        return out;
      }

      final dirs = keys(p.directors);
      final cast = keys(p.cast.take(castNames));
      for (final k in dirs) {
        directed.update(k, (v) => v + 1, ifAbsent: () => 1);
      }
      for (final k in cast) {
        starred.update(k, (v) => v + 1, ifAbsent: () => 1);
      }
      for (final k in {...dirs, ...cast}) {
        titles.update(k, (v) => v + 1, ifAbsent: () => 1);
        final have = last[k];
        if (have == null || seen.isAfter(have)) last[k] = seen;
      }
    }
    final out = [
      for (final MapEntry(:key, value: n) in titles.entries)
        if (n >= minWatched)
          PersonStat(
            name: names[key]!,
            role: (directed[key] ?? 0) >= (starred[key] ?? 0) ? PersonRole.director : PersonRole.cast,
            titles: n,
            last: last[key],
          ),
    ];
    out.sort((a, b) {
      if (a.titles != b.titles) return b.titles.compareTo(a.titles);
      final la = a.last, lb = b.last;
      if (la != lb) {
        if (la == null) return 1;
        if (lb == null) return -1;
        return lb.compareTo(la);
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  /// [ranked] in the order the day tries them: today's person when one is
  /// already featured today, then those not featured in the last
  /// [ReelPool.personRest] days in rank order, then those who were, the one
  /// featured longest ago first. [featured] is [ReelPool.featuredPeople]
  /// (lower-case name → newest day featured), [today] is `YYYY-MM-DD`.
  static List<PersonStat> rotation(List<PersonStat> ranked, Map<String, String> featured, String today) {
    final todays = <PersonStat>[], fresh = <PersonStat>[], rested = <PersonStat>[];
    for (final p in ranked) {
      final day = featured[p.name.toLowerCase()];
      if (day == today) {
        todays.add(p);
      } else if (day == null) {
        fresh.add(p);
      } else {
        rested.add(p);
      }
    }
    // Stable: equal days keep their rank order.
    final byDay = [for (final (i, p) in rested.indexed) (i: i, p: p)]
      ..sort((a, b) {
        final c = featured[a.p.name.toLowerCase()]!.compareTo(featured[b.p.name.toLowerCase()]!);
        return c != 0 ? c : a.i.compareTo(b.i);
      });
    return [...todays, ...fresh, for (final x in byDay) x.p];
  }

  /// Whether [name] is one of a title's directors ([directors]) or among
  /// its first [castNames] cast names ([cast]); both lists joined with `|`,
  /// as in the index.
  static bool credits(String name, {required String directors, required String cast}) {
    final want = name.trim().toLowerCase();
    bool has(Iterable<String> list) => list.any((n) => n.trim().toLowerCase() == want);
    return has(directors.split('|')) || has(cast.split('|').take(castNames));
  }
}

/// The day's person and their unseen titles (D22, see [ReelPerson]): from
/// the brain's watched titles and the index only (no server reads), the
/// titles in code order (best public score first, unrated last), at most
/// [ReelPool.maxPerson]. Null when nobody qualifies or no qualifying
/// person has [ReelPerson.minUnseen] unseen titles. [titlesWith] stands in
/// for the index (tests).
Future<PersonPick?> personPick({
  required ReelLibrary library,
  required ReelStore store,
  required ReelPool pool,
  HistoryBrain? brain,
  Future<List<DeckEntry>> Function(String name)? titlesWith,
}) async {
  final b = brain ?? HistoryBrain.instance;
  final ranked = ReelPerson.rank(await b.watchedProfiles());
  if (ranked.isEmpty) {
    appLogger.i('[ReelDeck] person: nobody with ${ReelPerson.minWatched}+ watched titles');
    return null;
  }
  final today = ReelPool.dateOf(pool.now());
  final order = ReelPerson.rotation(ranked, await pool.featuredPeople(), today);
  final excluded = await store.excluded();
  final find = titlesWith ?? (name) => _titlesWith(library, name);
  for (final (tried, p) in order.take(ReelPerson.tries).indexed) {
    final cards = [
      for (final c in await library.cards(await find(p.name)))
        if (c.facts.seen.isUnseen && !excluded.contains(c.id)) c,
    ];
    if (cards.length < ReelPerson.minUnseen) continue;
    final rated = [
      for (final c in cards)
        if (ForYouDeck.publicScore(c.facts) case final s?) (c: c, s: s),
    ]..sort((x, y) => y.s.compareTo(x.s));
    final ordered = [
      for (final x in rated) x.c,
      for (final c in cards)
        if (ForYouDeck.publicScore(c.facts) == null) c,
    ];
    appLogger.i(
      '[ReelDeck] person: rank ${ranked.indexOf(p) + 1} of ${ranked.length} chosen (try ${tried + 1}), '
      '${p.role.name}, watched ${p.titles}, ${cards.length} unseen',
    );
    return (
      name: p.name,
      role: p.role,
      watched: p.titles,
      candidates: [
        for (final c in ordered.take(ReelPool.maxPerson))
          PoolCandidate(
            entry: DeckEntry(serverId: c.best.serverId, ratingKey: c.best.ratingKey),
            titleId: c.id,
            score: 0,
          ),
      ],
    );
  }
  appLogger.i('[ReelDeck] person: ${ranked.length} qualify, none with ${ReelPerson.minUnseen}+ unseen titles');
  return null;
}

/// Index titles [name] directed or is in the first [ReelPerson.castNames]
/// cast names of, one row per title (`group_key`).
Future<List<DeckEntry>> _titlesWith(ReelLibrary library, String name) async {
  final db = await library.database();
  final like = '%${name.trim()}%';
  final rows = await db
      .customSelect(
        'SELECT * FROM index_titles WHERE directors LIKE ? OR "cast" LIKE ? LIMIT ?',
        variables: [Variable<String>(like), Variable<String>(like), Variable<int>(ReelPerson.rowsRead)],
        readsFrom: {db.indexTitles},
      )
      .get();
  final seen = <String>{};
  return [
    for (final r in rows)
      if (db.indexTitles.map(r.data) case final t
          when ReelPerson.credits(name, directors: t.directors, cast: t.cast) && seen.add(t.groupKey))
        DeckEntry(serverId: t.serverId, ratingKey: t.ratingKey),
  ];
}

/// A person you love (D22, build plan §3): one person a day whose work
/// they have watched a lot ([ReelPerson] says who and how they rotate),
/// their titles on the servers they haven't seen, in the daily build's
/// order once it has judged them (code order until then). The deck's name
/// names the person ("Directed by …", "Starring …"); its intro card says
/// how many titles with them they have watched. It follows For You's day
/// and takes its fresh builds through For You's [rebuilt].
class PersonDeck extends ReelDeck {
  PersonDeck({required this.forYou, required this.library});

  final ForYouDeck forYou;
  final ReelLibrary library;
  PersonList? _list;
  ReelDeckIntro? _intro;

  static const String deckId = 'person';

  @override
  String get id => deckId;

  @override
  String get name => nameFor(_list);

  /// The deck's name for [list]: the person by their role, or the deck's
  /// own name while no person is kept for today.
  static String nameFor(PersonList? list) {
    if (list == null) return t.reel.deckNames.person;
    return list.role == PersonRole.director
        ? t.reel.deckNames.directedBy(name: list.name)
        : t.reel.deckNames.starring(name: list.name);
  }

  @override
  bool get keepsSeen => false;

  /// The build's order (or code order) is kept as it is.
  @override
  bool get raw => true;
  @override
  bool get daily => true;
  @override
  Listenable get rebuilt => forYou.rebuilt;
  @override
  ReelDeckIntro? get intro => _intro;

  /// Today's person as kept, without gathering: names the deck before its
  /// first load (the deck strip, the remote).
  Future<void> peek() async {
    try {
      _list = await forYou.pool.cachedPerson();
    } catch (e) {
      appLogger.d('Reel: Person deck unavailable', error: e);
    }
  }

  @override
  Future<List<ReelCardData>> load() async {
    // The first Reel open of the day may land here: it starts today's build
    // (which orders this deck too) without waiting for it.
    try {
      await forYou.buildIfDue();
    } catch (e) {
      appLogger.d('Reel: build check failed', error: e);
    }
    var list = await forYou.pool.cachedPerson();
    if (list == null) {
      await forYou.todaysPerson();
      list = await forYou.pool.cachedPerson();
    }
    _list = list;
    if (list == null) {
      _intro = null;
      appLogger.i('[ReelDeck] person: no person today');
      return const [];
    }
    final cards = await library.cards(list.entries);
    _intro = ReelDeckIntro(
      line: introLine(watched: list.watched, unseen: cards.length),
    );
    appLogger.i(
      '[ReelDeck] person: ${list.day}, ${list.role.name}, watched ${list.watched}, '
      '${list.ai ? 'build' : 'code'} order, ${cards.length} left',
    );
    return cards;
  }

  /// "You've watched 5 titles with them. 12 you haven't seen."
  static String introLine({required int watched, required int unseen}) {
    final s = t.reel.person;
    return s.line(
      watched: s.watched(n: watched),
      unseen: s.unseen(n: unseen),
    );
  }
}
