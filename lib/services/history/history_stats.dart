import 'history_models.dart';

/// Fork: the numbers at the top of the History page, for one year or all
/// time. Pure, so it can be tested.
class HistoryStats {
  HistoryStats._({
    required this.plays,
    required this.films,
    required this.episodes,
    required this.shows,
    required this.minutes,
    required this.filmMinutes,
    required this.minutesEstimated,
    required this.currentStreak,
    required this.bestStreak,
    required this.byMonth,
    required this.topGenres,
    required this.topDirectors,
    required this.topCast,
    required this.rewatches,
    required this.decades,
    required this.longestBinge,
    required this.bulkCounted,
  });

  /// The dated watches in the period, newest first (the timeline).
  final List<HistoryPlay> plays;

  /// Watches counted in the totals whose date isn't real (imports and
  /// mark-as-watched; all-time only), left out of months, streaks and binges.
  final int bulkCounted;
  final int films;
  final int episodes;

  /// Distinct shows with an episode watched.
  final int shows;
  final int minutes;
  final int filmMinutes;

  /// Watches with no known runtime, counted at [fallbackFilmMinutes] /
  /// [fallbackEpisodeMinutes].
  final int minutesEstimated;

  /// Days in a row with a watch, ending today (or yesterday).
  final int currentStreak;
  final int bestStreak;

  /// Watches per month: `DateTime(year, month)` → count, oldest first.
  final Map<DateTime, int> byMonth;
  final List<MapEntry<String, int>> topGenres;
  final List<MapEntry<String, int>> topDirectors;
  final List<MapEntry<String, int>> topCast;

  /// Titles watched more than once in the period, most watched first.
  final List<MapEntry<HistoryPlay, int>> rewatches;

  /// Films by release decade (1990 → count).
  final Map<int, int> decades;

  /// Most episodes of one show on one day.
  final ({HistoryPlay play, int episodes})? longestBinge;

  int get hours => (minutes / 60).round();
  int get filmHours => (filmMinutes / 60).round();
  int get tvHours => ((minutes - filmMinutes) / 60).round();

  static const fallbackFilmMinutes = 110;
  static const fallbackEpisodeMinutes = 40;

  /// Years with a watch, newest first.
  static List<int> yearsOf(List<HistoryPlay> plays) => ({
    for (final p in plays)
      if (!p.bulk) p.watchedAt.toLocal().year,
  }.toList()..sort((a, b) => b.compareTo(a)));

  static HistoryStats compute(List<HistoryPlay> all, {int? year, DateTime? now}) {
    final today = _day((now ?? DateTime.now()).toLocal());
    // A year counts real dates only; all time also counts bulk-dated ones.
    final counted = [
      for (final p in all)
        if (year == null || (!p.bulk && p.watchedAt.toLocal().year == year)) p,
    ];
    final plays = [
      for (final p in counted)
        if (!p.bulk) p,
    ];

    var films = 0, episodes = 0, minutes = 0, filmMinutes = 0, estimated = 0;
    final shows = <String>{};
    final byMonth = <DateTime, int>{};
    final genres = <String, int>{}, directors = <String, int>{}, cast = <String, int>{};
    final perTitle = <String, int>{};
    final firstOfTitle = <String, HistoryPlay>{};
    final decades = <int, int>{};
    final days = <DateTime>{};
    final binges = <String, int>{};
    final bingePlay = <String, HistoryPlay>{};
    final bulkShows = <String>{};

    for (final p in counted) {
      final local = p.watchedAt.toLocal();
      final day = _day(local);
      if (!p.bulk) {
        days.add(day);
        byMonth.update(DateTime(local.year, local.month), (n) => n + 1, ifAbsent: () => 1);
      }
      var runtime = p.runtimeMinutes;
      if (runtime == null || runtime <= 0) {
        estimated++;
        runtime = p.isMovie ? fallbackFilmMinutes : fallbackEpisodeMinutes;
      }
      minutes += runtime;
      if (p.isMovie) {
        films++;
        filmMinutes += runtime;
        if (p.year != null) decades.update(p.year! ~/ 10 * 10, (n) => n + 1, ifAbsent: () => 1);
        for (final d in p.directors) {
          directors.update(d, (n) => n + 1, ifAbsent: () => 1);
        }
      } else {
        episodes++;
        shows.add(p.titleKey);
        final bingeKey = '${p.titleKey}@${p.bulk ? 'bulk' : day.toIso8601String()}';
        if (!p.bulk) {
          binges.update(bingeKey, (n) => n + 1, ifAbsent: () => 1);
          bingePlay.putIfAbsent(bingeKey, () => p);
        }
      }
      // Genres and cast count each title once per watch of a film, once per
      // show-day for TV, so a binge doesn't swamp them.
      if (p.isMovie || (p.bulk ? bulkShows.add(p.titleKey) : binges['${p.titleKey}@${day.toIso8601String()}'] == 1)) {
        for (final g in p.genres) {
          genres.update(g, (n) => n + 1, ifAbsent: () => 1);
        }
        for (final c in p.cast.take(5)) {
          cast.update(c, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      perTitle.update(p.watchKey, (n) => n + 1, ifAbsent: () => 1);
      firstOfTitle.putIfAbsent(p.watchKey, () => p);
    }

    final sortedDays = days.toList()..sort();
    var best = 0, run = 0;
    DateTime? prev;
    for (final d in sortedDays) {
      run = (prev != null && d.difference(prev).inDays == 1) ? run + 1 : 1;
      if (run > best) best = run;
      prev = d;
    }
    var current = 0;
    if (year == null || year == today.year) {
      var cursor = days.contains(today) ? today : today.subtract(const Duration(days: 1));
      while (days.contains(cursor)) {
        current++;
        cursor = _day(cursor.subtract(const Duration(hours: 12)));
      }
    }

    ({HistoryPlay play, int episodes})? longest;
    for (final e in binges.entries) {
      if (longest == null || e.value > longest.episodes) longest = (play: bingePlay[e.key]!, episodes: e.value);
    }

    List<MapEntry<String, int>> top(Map<String, int> m) =>
        (m.entries.toList()..sort((a, b) => b.value != a.value ? b.value - a.value : a.key.compareTo(b.key)))
            .take(10)
            .toList();

    return HistoryStats._(
      plays: plays,
      films: films,
      episodes: episodes,
      shows: shows.length,
      minutes: minutes,
      filmMinutes: filmMinutes,
      minutesEstimated: estimated,
      currentStreak: current,
      bestStreak: best,
      byMonth: Map.fromEntries(byMonth.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
      topGenres: top(genres),
      topDirectors: top(directors),
      topCast: top(cast),
      rewatches: [
        for (final e in (perTitle.entries.where((e) => e.value > 1).toList()..sort((a, b) => b.value - a.value)))
          MapEntry(firstOfTitle[e.key]!, e.value),
      ],
      decades: Map.fromEntries(decades.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
      longestBinge: longest != null && longest.episodes > 1 ? longest : null,
      bulkCounted: counted.length - plays.length,
    );
  }

  static DateTime _day(DateTime local) => DateTime(local.year, local.month, local.day);
}
