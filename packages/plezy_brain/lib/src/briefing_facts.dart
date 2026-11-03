import 'history_query.dart';
import 'title_profile.dart';

/// The facts a daily briefing is written from, as compact text for a
/// model: what the user has been into lately, shows they're partway
/// through, rewatch and Comfort candidates, and a few patterns. Computed
/// here, so the model only phrases them and never has to count.
///
/// [cardId] names a title for the model (the id it should hand back);
/// titles without one are left out of the suggestion lists. [newEpisodes]:
/// shows with episodes added since the user last watched them.
String briefingFacts(
  List<TitleProfile> watched, {
  required DateTime now,
  required String? Function(TitleProfile) cardId,
  Set<String> newEpisodes = const {},
}) {
  final local = now.toLocal();
  final b = StringBuffer('Today: ${_day(local)} (${_weekdays[local.weekday - 1]})\n');
  String name(TitleProfile p) => '${p.title}${p.year == null ? '' : ' (${p.year})'}';
  String ref(TitleProfile p) => cardId(p) == null ? name(p) : '${name(p)} [${cardId(p)}]';

  // Lately: the last 30 days.
  final month = HistoryQuery(watchedFrom: now.subtract(const Duration(days: 30)), watchedTo: now);
  final recent = [
    for (final p in watched)
      if (month.watchesIn(p).isNotEmpty) p,
  ];
  if (recent.isEmpty) {
    b.writeln('Last 30 days: nothing watched.');
  } else {
    final total = historyStats(recent, month, HistoryGroup.kind, now: now);
    final plays = total.fold<int>(0, (n, r) => n + r.plays);
    final hours = (total.fold<int>(0, (n, r) => n + r.minutes) / 60).round();
    final genres = historyStats(recent, month, HistoryGroup.genre, now: now, limit: 4);
    final top = [...recent]..sort((a, c) => month.watchesIn(c).length.compareTo(month.watchesIn(a).length));
    b.writeln(
      'Last 30 days: $plays watches, about $hours hours, ${recent.length} titles. '
      'Top genres: ${genres.map((g) => '${g.group} (${g.titles} titles)').join(', ')}.',
    );
    b.writeln(
      'Most watched lately: ${top.take(5).map((p) => '${ref(p)}: ${month.watchesIn(p).length} '
          '${p.isMovie ? 'watch' : 'episodes'}').join('; ')}.',
    );
  }

  // Partway through.
  final partway = [
    for (final p in watched)
      if (p.progress(now) == ShowProgress.inProgress && cardId(p) != null) p,
  ]..sort((a, c) => c.lastWatched!.compareTo(a.lastWatched!));
  if (partway.isNotEmpty) {
    b.writeln('Partway through (most recent first):');
    for (final p in partway.take(5)) {
      b.writeln(
        '- ${ref(p)}: ${p.episodesWatched}/${p.episodeCount} episodes, last watched ${_day(p.lastWatched!.toLocal())}'
        '${newEpisodes.contains(p.id) ? ', NEW EPISODES added since' : ''}',
      );
    }
  }
  final returning = [
    for (final p in watched)
      if (newEpisodes.contains(p.id) && !partway.contains(p) && cardId(p) != null) p,
  ];
  if (returning.isNotEmpty) {
    b.writeln('New episodes for shows they watched before: ${returning.take(5).map(ref).join('; ')}.');
  }

  // Rewatch and Comfort nudges.
  final yearAgo = now.subtract(const Duration(days: 365));
  final comfort = [
    for (final p in watched)
      if (p.comfort && cardId(p) != null && (p.lastWatched == null || now.difference(p.lastWatched!).inDays > 30)) p,
  ];
  if (comfort.isNotEmpty) {
    b.writeln('Comfort shows not watched for a month or more: ${comfort.take(5).map(ref).join('; ')}.');
  }
  final loved = [
    for (final p in watched)
      if (p.isMovie &&
          cardId(p) != null &&
          ((p.myRating ?? 0) >= 8 || p.plays > 1) &&
          p.lastWatched != null &&
          p.lastWatched!.isBefore(yearAgo))
        p,
  ]..sort((a, c) => (c.myRating ?? 0).compareTo(a.myRating ?? 0));
  if (loved.isNotEmpty) {
    b.writeln(
      'Films they rated highly or rewatched, not seen for a year+: '
      '${loved.take(5).map((p) => '${ref(p)}${p.myRating == null ? '' : ' rated ${p.myRating}'}').join('; ')}.',
    );
  }
  final thisWeekLastYear = HistoryQuery(
    watchedFrom: yearAgo.subtract(const Duration(days: 3)),
    watchedTo: yearAgo.add(const Duration(days: 4)),
  );
  final lastYear = thisWeekLastYear.run(watched, now: now).take(4).toList();
  if (lastYear.isNotEmpty) b.writeln('This week last year they watched: ${lastYear.map(ref).join('; ')}.');

  // Patterns, for one fun line.
  final all = [for (final p in watched) ...p.watches.map((w) => w.toLocal())];
  if (all.length >= 20) {
    final byDay = List.filled(7, 0), byHour = List.filled(24, 0);
    for (final w in all) {
      byDay[w.weekday - 1]++;
      byHour[w.hour]++;
    }
    final busiestDay = _argMax(byDay);
    final busiestHour = _argMax(byHour);
    b.writeln(
      'Patterns: busiest day ${_weekdays[busiestDay]} (${(100 * byDay[busiestDay] / all.length).round()}% of '
      'watches); most common hour ${busiestHour.toString().padLeft(2, '0')}:00.',
    );
    final decades = historyStats(watched, const HistoryQuery(kind: TitleKind.movie), HistoryGroup.decade, now: now);
    if (decades.isNotEmpty) {
      b.writeln('Films by decade (titles): ${decades.take(5).map((d) => '${d.group} ${d.titles}').join(', ')}.');
    }
    final rewatchedCount = watched.where((p) => p.rewatched).length;
    b.writeln('Titles rewatched at least once: $rewatchedCount of ${watched.length}.');
    final streak = _streak(all, local);
    if (streak > 1) b.writeln('Current streak: $streak days in a row with something watched.');
  }
  return b.toString();
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String _day(DateTime d) => d.toIso8601String().substring(0, 10);

int _argMax(List<int> v) {
  var best = 0;
  for (var i = 1; i < v.length; i++) {
    if (v[i] > v[best]) best = i;
  }
  return best;
}

int _streak(List<DateTime> watches, DateTime today) {
  final days = {for (final w in watches) DateTime(w.year, w.month, w.day)};
  var cursor = DateTime(today.year, today.month, today.day);
  if (!days.contains(cursor)) cursor = cursor.subtract(const Duration(days: 1));
  var n = 0;
  while (days.contains(cursor)) {
    n++;
    cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
  }
  return n;
}
