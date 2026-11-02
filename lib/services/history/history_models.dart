/// Fork: one watch in the History page, from Plex (its last-viewed date) or
/// Trakt (its history), merged so the same watch is listed once.
library;

enum HistoryKind { movie, episode }

enum HistorySource { plex, trakt }

class HistoryPlay {
  HistoryPlay({
    required this.kind,
    required this.watchedAt,
    required this.title,
    required Set<HistorySource> sources,
    this.episodeTitle,
    this.season,
    this.episode,
    this.year,
    this.runtimeMinutes,
    this.imdb,
    this.tmdb,
    this.tvdb,
    this.traktId,
    this.traktHistoryId,
    this.genres = const [],
    this.directors = const [],
    this.cast = const [],
    this.plexServerId,
    this.plexRatingKey,
    this.plexThumb,
    this.posterUrl,
    this.datedAtRelease = false,
  }) : sources = {...sources};

  final HistoryKind kind;

  /// UTC.
  final DateTime watchedAt;

  /// The film's title, or the show's for an episode.
  final String title;
  final String? episodeTitle;
  final int? season;
  final int? episode;

  /// Release year (the show's first year for an episode).
  final int? year;
  int? runtimeMinutes;

  /// The film's ids, or the show's for an episode.
  String? imdb;
  String? tmdb;
  String? tvdb;
  int? traktId;

  /// Trakt's id for this history entry (unique per watch).
  final int? traktHistoryId;
  List<String> genres;
  List<String> directors;
  List<String> cast;
  final Set<HistorySource> sources;

  /// The film, or the show for an episode, on a Plex server.
  String? plexServerId;
  String? plexRatingKey;

  /// Plex image path (needs the server to resolve).
  String? plexThumb;

  /// Absolute poster URL (Trakt).
  String? posterUrl;

  /// Trakt's date is the title's release day (its "watched on release"
  /// option), not a viewing.
  final bool datedAtRelease;

  /// Its date is an import or a "mark all watched", not a viewing (set by
  /// [mergeHistory]; see [markBulkDates]).
  bool bulk = false;

  bool get isMovie => kind == HistoryKind.movie;

  /// The film or show this watch is of, across Plex and Trakt.
  String get titleKey {
    final prefix = isMovie ? 'm' : 's';
    if (imdb != null && imdb!.isNotEmpty) return '$prefix:imdb:$imdb';
    if (tmdb != null && tmdb!.isNotEmpty) return '$prefix:tmdb:$tmdb';
    if (!isMovie && tvdb != null && tvdb!.isNotEmpty) return '$prefix:tvdb:$tvdb';
    return '$prefix:title:${title.toLowerCase().trim()}|${year ?? ''}';
  }

  /// This film, or this episode of the show.
  String get watchKey => isMovie ? titleKey : '$titleKey:${season ?? 0}x${episode ?? 0}';

  Map<String, dynamic> toJson() => {
    'k': kind.name,
    'at': watchedAt.millisecondsSinceEpoch,
    't': title,
    if (episodeTitle != null) 'et': episodeTitle,
    if (season != null) 's': season,
    if (episode != null) 'e': episode,
    if (year != null) 'y': year,
    if (runtimeMinutes != null) 'rt': runtimeMinutes,
    if (imdb != null) 'imdb': imdb,
    if (tmdb != null) 'tmdb': tmdb,
    if (tvdb != null) 'tvdb': tvdb,
    if (traktId != null) 'trakt': traktId,
    if (traktHistoryId != null) 'th': traktHistoryId,
    if (genres.isNotEmpty) 'g': genres,
    if (directors.isNotEmpty) 'd': directors,
    if (cast.isNotEmpty) 'c': cast,
    'src': [for (final s in sources) s.name],
    if (plexServerId != null) 'ps': plexServerId,
    if (plexRatingKey != null) 'pk': plexRatingKey,
    if (plexThumb != null) 'pt': plexThumb,
    if (posterUrl != null) 'pu': posterUrl,
    if (datedAtRelease) 'rel': true,
  };

  static HistoryPlay fromJson(Map<String, dynamic> j) {
    List<String> strings(Object? v) => v is List ? [for (final s in v) '$s'] : const [];
    return HistoryPlay(
      kind: j['k'] == 'episode' ? HistoryKind.episode : HistoryKind.movie,
      watchedAt: DateTime.fromMillisecondsSinceEpoch(j['at'] as int, isUtc: true),
      title: j['t'] as String? ?? '',
      episodeTitle: j['et'] as String?,
      season: j['s'] as int?,
      episode: j['e'] as int?,
      year: j['y'] as int?,
      runtimeMinutes: j['rt'] as int?,
      imdb: j['imdb'] as String?,
      tmdb: j['tmdb'] as String?,
      tvdb: j['tvdb'] as String?,
      traktId: j['trakt'] as int?,
      traktHistoryId: j['th'] as int?,
      genres: strings(j['g']),
      directors: strings(j['d']),
      cast: strings(j['c']),
      sources: {
        for (final s in strings(j['src']))
          if (s == 'plex') HistorySource.plex else HistorySource.trakt,
      },
      plexServerId: j['ps'] as String?,
      plexRatingKey: j['pk'] as String?,
      plexThumb: j['pt'] as String?,
      posterUrl: j['pu'] as String?,
      datedAtRelease: j['rel'] == true,
    );
  }
}

/// Entries with no real date (Trakt stores "unknown" as 1970).
bool isUndatedWatch(DateTime at) => at.year < 1971;

/// Flag watches whose date is shared by others minutes apart: an import
/// into Trakt or a "mark as watched" of a season or show, not a viewing.
/// Two rules: [threshold] or more within one [bucket] (imports), or
/// [tightThreshold] or more within one [tightBucket] (nobody watches four
/// episodes in two minutes).
void markBulkDates(
  List<HistoryPlay> plays, {
  int threshold = 15,
  Duration bucket = const Duration(minutes: 10),
  int tightThreshold = 4,
  Duration tightBucket = const Duration(minutes: 2),
}) {
  Map<int, int> count(Duration size) {
    final counts = <int, int>{};
    for (final p in plays) {
      counts.update(p.watchedAt.millisecondsSinceEpoch ~/ size.inMilliseconds, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  final wide = count(bucket), tight = count(tightBucket);
  for (final p in plays) {
    final ms = p.watchedAt.millisecondsSinceEpoch;
    p.bulk =
        p.datedAtRelease ||
        wide[ms ~/ bucket.inMilliseconds]! >= threshold ||
        tight[ms ~/ tightBucket.inMilliseconds]! >= tightThreshold;
  }
}

/// Merge Trakt's history with Plex's last-viewed dates, one entry per watch.
///
/// - A Plex watch within [sameWatchWindow] of a Trakt watch of the same film
///   (or episode) is that watch: listed once, with both sources.
/// - A bulk-dated watch (see [markBulkDates]) on one side and a watch of the
///   same item on the other are the same watch; the real date wins.
/// - Plex episodes whose show has no ids take them from a Trakt show of the
///   same name, so they can match.
/// - Every watch picks up what the other side knows about its title
///   (runtime, genres, people, Plex location, poster).
///
/// Undated Trakt entries are dropped and counted in [MergedHistory.undated].
/// Newest first.
MergedHistory mergeHistory({
  required List<HistoryPlay> trakt,
  required List<HistoryPlay> plex,
  Duration sameWatchWindow = const Duration(hours: 36),
}) {
  final undated = trakt.where((p) => isUndatedWatch(p.watchedAt)).length;
  final traktPlays = [
    for (final p in trakt)
      if (!isUndatedWatch(p.watchedAt)) p,
  ];
  markBulkDates(traktPlays);
  markBulkDates(plex);

  final traktShowsByName = <String, HistoryPlay>{};
  for (final p in traktPlays) {
    if (!p.isMovie) traktShowsByName.putIfAbsent(p.title.toLowerCase().trim(), () => p);
  }
  for (final p in plex) {
    if (p.isMovie || p.imdb != null || p.tmdb != null || p.tvdb != null) continue;
    final show = traktShowsByName[p.title.toLowerCase().trim()];
    if (show == null) continue;
    p
      ..imdb = show.imdb
      ..tmdb = show.tmdb
      ..tvdb = show.tvdb;
  }

  final traktByWatch = <String, List<HistoryPlay>>{};
  for (final p in traktPlays) {
    (traktByWatch[p.watchKey] ??= []).add(p);
  }

  final dropped = <HistoryPlay>{};
  final plays = <HistoryPlay>[];
  var matched = 0;
  for (final p in plex) {
    final candidates = [...?traktByWatch[p.watchKey]?.where((t) => !dropped.contains(t))];
    if (candidates.isEmpty) {
      plays.add(p);
      continue;
    }
    final near = candidates.where((t) => t.watchedAt.difference(p.watchedAt).abs() <= sameWatchWindow);
    if (near.isNotEmpty) {
      near.first.sources.add(HistorySource.plex);
      matched++;
    } else if (p.bulk) {
      // Plex's date is a mark-as-watched; Trakt has the watch.
      candidates.first.sources.add(HistorySource.plex);
      matched++;
    } else if (candidates.where((t) => t.bulk).firstOrNull case final imported?) {
      // Trakt's date is an import; Plex has the real one.
      dropped.add(imported);
      p.sources.add(HistorySource.trakt);
      p.traktId ??= imported.traktId;
      plays.add(p);
      matched++;
    } else {
      plays.add(p); // A later rewatch Plex saw.
    }
  }
  plays.addAll(traktPlays.where((p) => !dropped.contains(p)));

  // What each side knows about a title, for every watch of it.
  final plexByTitle = <String, HistoryPlay>{};
  for (final p in plex) {
    plexByTitle.putIfAbsent(p.titleKey, () => p);
  }
  final traktByTitle = <String, HistoryPlay>{};
  for (final p in traktPlays) {
    traktByTitle.putIfAbsent(p.titleKey, () => p);
  }
  for (final p in plays) {
    final fromPlex = plexByTitle[p.titleKey];
    if (fromPlex != null && !identical(fromPlex, p)) {
      p.plexServerId ??= fromPlex.plexServerId;
      p.plexRatingKey ??= fromPlex.plexRatingKey;
      p.plexThumb ??= fromPlex.plexThumb;
      if (p.genres.isEmpty) p.genres = fromPlex.genres;
      if (p.directors.isEmpty) p.directors = fromPlex.directors;
      if (p.cast.isEmpty) p.cast = fromPlex.cast;
      if (p.isMovie) p.runtimeMinutes ??= fromPlex.runtimeMinutes;
    }
    final fromTrakt = traktByTitle[p.titleKey];
    if (fromTrakt != null && !identical(fromTrakt, p)) {
      p.posterUrl ??= fromTrakt.posterUrl;
      p.traktId ??= fromTrakt.traktId;
      p.imdb ??= fromTrakt.imdb;
      p.tmdb ??= fromTrakt.tmdb;
      if (p.genres.isEmpty) p.genres = fromTrakt.genres;
    }
  }

  plays.sort((a, b) => b.watchedAt.compareTo(a.watchedAt));
  return MergedHistory(plays: plays, undated: undated, matched: matched);
}

class MergedHistory {
  const MergedHistory({required this.plays, required this.undated, required this.matched});

  /// Newest first.
  final List<HistoryPlay> plays;

  /// Trakt watches with no date (not in [plays]).
  final int undated;

  /// Plex watches that were already on Trakt.
  final int matched;

  /// Watches whose date is an import or a mark-as-watched.
  int get bulk => plays.where((p) => p.bulk).length;
}
