import 'history_query.dart';
import 'title_profile.dart';

/// The user's taste as compact text for a model's first prompt: what they
/// love, what they've watched lately, what didn't stick, and their genres.
/// With it a recommendation needs no history lookups first.
///
/// Built from [watched] only (no ids: picks still come from the tools).
String tasteSummary(List<TitleProfile> watched, {required DateTime now}) {
  if (watched.isEmpty) return '';
  String name(TitleProfile p) => '${p.title}${p.year == null ? '' : ' (${p.year})'}';
  String kind(TitleProfile p) => p.isMovie ? 'film' : 'show';
  final b = StringBuffer();

  final recent = [...watched.where((p) => p.lastWatched != null)]
    ..sort((a, c) => c.lastWatched!.compareTo(a.lastWatched!));
  if (recent.isNotEmpty) {
    b.writeln('Watched lately (newest first):');
    for (final p in recent.take(25)) {
      final progress = p.progress(now);
      final state = switch (progress) {
        ShowProgress.none || ShowProgress.unknown => '',
        ShowProgress.finished => ', finished',
        ShowProgress.inProgress => ', watching (${p.episodesWatched}/${p.episodeCount} eps)',
        _ => ', ${progress.name} (${p.episodesWatched}/${p.episodeCount} eps)',
      };
      final rating = p.myRating == null ? '' : ', rated ${p.myRating}/10';
      b.writeln('- ${name(p)}, ${kind(p)}, ${_month(p.lastWatched!.toLocal())}$state$rating');
    }
  }

  int score(TitleProfile p) => (p.myRating ?? 0) * 10 + (p.rewatched ? 15 : 0) + (p.comfort ? 20 : 0);
  final loved = [
    for (final p in watched)
      if ((p.myRating ?? 0) >= 8 || p.rewatched || p.comfort || p.progress(now) == ShowProgress.finished) p,
  ]..sort((a, c) => score(c) != score(a) ? score(c) - score(a) : c.plays - a.plays);
  final recentNames = recent.take(25).toSet();
  final lovedRest = [for (final p in loved) if (!recentNames.contains(p)) p];
  if (lovedRest.isNotEmpty) {
    b.writeln(
      'Loved (rated 8+, rewatched, Comfort or finished shows): '
      '${lovedRest.take(30).map((p) => '${name(p)}${p.myRating == null ? '' : ' ${p.myRating}/10'}').join('; ')}.',
    );
  }

  final stalled = [
    for (final p in recent)
      if (p.progress(now) == ShowProgress.dropped || p.progress(now) == ShowProgress.sampled) p,
  ];
  final disliked = [
    for (final p in watched)
      if (p.myRating != null && p.myRating! <= 4) p,
  ];
  if (stalled.isNotEmpty || disliked.isNotEmpty) {
    b.writeln(
      "Didn't stick (dropped, only sampled, or rated 4 or less): "
      '${{...disliked, ...stalled}.take(15).map(name).join('; ')}.',
    );
  }

  final year = HistoryQuery(watchedFrom: now.subtract(const Duration(days: 365)), watchedTo: now);
  final genresYear = historyStats(watched, year, HistoryGroup.genre, now: now, limit: 8);
  final genresAll = historyStats(watched, const HistoryQuery(), HistoryGroup.genre, now: now, limit: 8);
  if (genresYear.isNotEmpty) {
    b.writeln('Top genres, last 12 months (titles): ${genresYear.map((g) => '${g.group} ${g.titles}').join(', ')}.');
  }
  if (genresAll.isNotEmpty) {
    b.writeln('Top genres, all time (titles): ${genresAll.map((g) => '${g.group} ${g.titles}').join(', ')}.');
  }
  final kinds = historyStats(watched, year, HistoryGroup.kind, now: now);
  if (kinds.isNotEmpty) {
    b.writeln('Last 12 months: ${kinds.map((k) => '${k.plays} ${k.group} watches').join(', ')}.');
  }
  return b.toString();
}

String _month(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
