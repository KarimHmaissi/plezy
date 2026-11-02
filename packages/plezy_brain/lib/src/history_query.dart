import 'title_profile.dart';

/// How to order [HistoryQuery] results.
enum HistorySort { lastWatched, firstWatched, plays, myRating, year, title }

/// What to count titles by in [historyStats].
enum HistoryGroup { year, month, genre, kind, decade, director, actor, collection, studio, progress }

/// A structured question over watched titles: every field narrows it.
class HistoryQuery {
  const HistoryQuery({
    this.kind,
    this.watchedFrom,
    this.watchedTo,
    this.genresAny = const [],
    this.genresAll = const [],
    this.person,
    this.collection,
    this.studio,
    this.titleContains,
    this.rewatched,
    this.progress = const {},
    this.minMyRating,
    this.comfort,
    this.watchlist,
    this.inLibrary,
    this.sort = HistorySort.lastWatched,
    this.limit = 25,
  });

  final TitleKind? kind;

  /// A real watch (not an import) on or after / before these.
  final DateTime? watchedFrom;
  final DateTime? watchedTo;
  final List<String> genresAny;
  final List<String> genresAll;

  /// Actor or director, case-insensitive substring.
  final String? person;
  final String? collection;

  /// Production studio, case-insensitive substring ("Marvel Studios").
  final String? studio;
  final String? titleContains;
  final bool? rewatched;

  /// Shows in any of these states.
  final Set<ShowProgress> progress;
  final int? minMyRating;
  final bool? comfort;
  final bool? watchlist;
  final bool? inLibrary;
  final HistorySort sort;
  final int limit;

  bool get hasDateRange => watchedFrom != null || watchedTo != null;

  /// Watches of [p] inside the date range (all real watches without one).
  List<DateTime> watchesIn(TitleProfile p) => [
    for (final w in p.watches)
      if ((watchedFrom == null || !w.isBefore(watchedFrom!)) && (watchedTo == null || w.isBefore(watchedTo!))) w,
  ];

  bool matches(TitleProfile p, DateTime now) {
    if (!p.watched) return false;
    if (kind != null && p.kind != kind) return false;
    if (hasDateRange && watchesIn(p).isEmpty) return false;
    bool has(List<String> list, String want) => list.any((g) => g.toLowerCase() == want.toLowerCase());
    if (genresAny.isNotEmpty && !genresAny.any((g) => has(p.genres, g))) return false;
    if (genresAll.isNotEmpty && !genresAll.every((g) => has(p.genres, g))) return false;
    bool contains(Iterable<String> list, String want) =>
        list.any((s) => s.toLowerCase().contains(want.toLowerCase().trim()));
    if (person != null && !contains([...p.cast, ...p.directors], person!)) return false;
    if (collection != null && !contains(p.collections, collection!)) return false;
    if (studio != null && !contains([?p.studio], studio!)) return false;
    if (titleContains != null && !contains([p.title], titleContains!)) return false;
    if (rewatched != null && p.rewatched != rewatched) return false;
    if (progress.isNotEmpty && !progress.contains(p.progress(now))) return false;
    if (minMyRating != null && (p.myRating ?? 0) < minMyRating!) return false;
    if (comfort != null && p.comfort != comfort) return false;
    if (watchlist != null && p.watchlist != watchlist) return false;
    if (inLibrary != null && p.inLibrary != inLibrary) return false;
    return true;
  }

  /// Matching titles, sorted; [limit] of them.
  List<TitleProfile> run(Iterable<TitleProfile> all, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final hits = [
      for (final p in all)
        if (matches(p, at)) p,
    ];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    DateTime last(TitleProfile p) => (hasDateRange ? watchesIn(p).lastOrNull : p.lastWatched) ?? epoch;
    int plays(TitleProfile p) => hasDateRange ? watchesIn(p).length : p.plays;
    hits.sort(
      (a, b) => switch (sort) {
        HistorySort.lastWatched => last(b).compareTo(last(a)),
        HistorySort.firstWatched => (a.firstWatched ?? epoch).compareTo(b.firstWatched ?? epoch),
        HistorySort.plays => plays(b).compareTo(plays(a)),
        HistorySort.myRating => (b.myRating ?? 0).compareTo(a.myRating ?? 0),
        HistorySort.year => (b.year ?? 0).compareTo(a.year ?? 0),
        HistorySort.title => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      },
    );
    return hits.take(limit).toList();
  }
}

/// One row of [historyStats]: a group, its titles, watches and hours.
typedef HistoryStatRow = ({String group, int titles, int plays, int minutes});

/// Count the titles matching [query] by [group]. With a date range only the
/// watches inside it count. Titles with no runtime count [fallbackMinutes].
List<HistoryStatRow> historyStats(
  Iterable<TitleProfile> all,
  HistoryQuery query,
  HistoryGroup group, {
  DateTime? now,
  int limit = 30,
}) {
  final at = now ?? DateTime.now();
  final titles = <String, Set<String>>{};
  final plays = <String, int>{};
  final minutes = <String, int>{};
  for (final p in all) {
    if (!query.matches(p, at)) continue;
    final watches = query.watchesIn(p);
    final runtime = p.runtimeMinutes ?? (p.isMovie ? fallbackMovieMinutes : fallbackEpisodeMinutes);
    void add(String key, int n) {
      (titles[key] ??= {}).add(p.id);
      plays.update(key, (v) => v + n, ifAbsent: () => n);
      minutes.update(key, (v) => v + n * runtime, ifAbsent: () => n * runtime);
    }

    // Undated plays (imports) count toward totals only without a date range.
    final undated = query.hasDateRange ? 0 : p.bulkPlays;
    switch (group) {
      case HistoryGroup.year:
      case HistoryGroup.month:
        for (final w in watches) {
          final l = w.toLocal();
          add(group == HistoryGroup.year ? '${l.year}' : '${l.year}-${l.month.toString().padLeft(2, '0')}', 1);
        }
        if (undated > 0) add('undated', undated);
      default:
        final n = watches.length + undated;
        final keys = switch (group) {
          HistoryGroup.genre => p.genres,
          HistoryGroup.kind => [p.isMovie ? 'film' : 'show'],
          HistoryGroup.decade => [if (p.year != null) '${p.year! ~/ 10 * 10}s'],
          HistoryGroup.director => p.directors.take(2).toList(),
          HistoryGroup.actor => p.cast.take(5).toList(),
          HistoryGroup.collection => p.collections,
          HistoryGroup.studio => [?p.studio],
          HistoryGroup.progress => [p.isMovie ? 'film' : p.progress(at).name],
          _ => const <String>[],
        };
        for (final k in keys) {
          add(k, n);
        }
    }
  }
  final rows = [
    for (final k in titles.keys) (group: k, titles: titles[k]!.length, plays: plays[k]!, minutes: minutes[k]!),
  ];
  if (group == HistoryGroup.year || group == HistoryGroup.month) {
    rows.sort((a, b) => b.group.compareTo(a.group));
  } else {
    rows.sort((a, b) => b.titles != a.titles ? b.titles - a.titles : b.plays - a.plays);
  }
  return rows.take(limit).toList();
}

const int fallbackMovieMinutes = 110;
const int fallbackEpisodeMinutes = 40;
