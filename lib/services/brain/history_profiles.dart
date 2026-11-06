import 'package:plezy_brain/plezy_brain.dart';

import '../history/history_models.dart';
import '../library_index/index_database.dart';

/// Fork: what a tracker knows about a title that isn't in the library
/// (Trakt's `extended=full` summary plus its people), cached by
/// [TraktDetailsCache].
class TraktDetails {
  const TraktDetails({
    this.summary,
    this.tagline,
    this.genres = const [],
    this.runtime,
    this.rating,
    this.certification,
    this.country,
    this.airedEpisodes,
    this.directors = const [],
    this.cast = const [],
  });

  final String? summary;
  final String? tagline;
  final List<String> genres;
  final int? runtime;
  final double? rating;
  final String? certification;
  final String? country;
  final int? airedEpisodes;
  final List<String> directors;
  final List<String> cast;

  Map<String, Object?> toJson() => {
    's': ?summary,
    'tl': ?tagline,
    if (genres.isNotEmpty) 'g': genres,
    'rt': ?runtime,
    'r': ?rating,
    'cr': ?certification,
    'co': ?country,
    'ae': ?airedEpisodes,
    if (directors.isNotEmpty) 'd': directors,
    if (cast.isNotEmpty) 'c': cast,
  };

  static TraktDetails fromJson(Map<String, Object?> j) {
    List<String> strings(Object? v) => v is List ? [for (final s in v) '$s'] : const [];
    return TraktDetails(
      summary: j['s'] as String?,
      tagline: j['tl'] as String?,
      genres: strings(j['g']),
      runtime: j['rt'] as int?,
      rating: (j['r'] as num?)?.toDouble(),
      certification: j['cr'] as String?,
      country: j['co'] as String?,
      airedEpisodes: j['ae'] as int?,
      directors: strings(j['d']),
      cast: strings(j['c']),
    );
  }
}

/// The user's extras about titles, keyed by `imdb:…` / `tmdb:…` / `tvdb:…`
/// / `trakt:…` (any one matching is enough).
class TitleExtras {
  const TitleExtras({this.ratings = const {}, this.comfort = const {}, this.watchlist = const {}});

  final Map<String, int> ratings;
  final Set<String> comfort;
  final Set<String> watchlist;

  static List<String> keysOf({String? imdb, Object? tmdb, Object? tvdb, Object? trakt}) => [
    if (imdb != null && imdb.isNotEmpty) 'imdb:$imdb',
    if (tmdb != null && '$tmdb'.isNotEmpty) 'tmdb:$tmdb',
    if (tvdb != null && '$tvdb'.isNotEmpty) 'tvdb:$tvdb',
    if (trakt != null && '$trakt'.isNotEmpty) 'trakt:$trakt',
  ];
}

/// Fork: the few columns of a library row needed to match watches to it,
/// so the whole library never has to be in memory at once.
class LibraryRef {
  const LibraryRef({
    required this.rowId,
    required this.serverId,
    required this.ratingKey,
    required this.type,
    required this.title,
    required this.groupKey,
    this.year,
    this.imdb,
    this.tmdb,
    this.tvdb,
    this.episodeCount,
    this.watchedEpisodeCount,
    this.viewCount,
  });

  factory LibraryRef.of(IndexedTitle t) => LibraryRef(
    rowId: t.id,
    serverId: t.serverId,
    ratingKey: t.ratingKey,
    type: t.type,
    title: t.title,
    groupKey: t.groupKey,
    year: t.year,
    imdb: t.imdb,
    tmdb: t.tmdb,
    tvdb: t.tvdb,
    episodeCount: t.episodeCount,
    watchedEpisodeCount: t.watchedEpisodeCount,
    viewCount: t.viewCount,
  );

  /// The index row's id (`serverId:ratingKey`).
  final String rowId;
  final String serverId;
  final String ratingKey;
  final String type;
  final String title;
  final String groupKey;
  final int? year;
  final String? imdb;
  final String? tmdb;
  final String? tvdb;
  final int? episodeCount;
  final int? watchedEpisodeCount;
  final int? viewCount;

  bool get isMovie => type == 'movie';

  /// The brain id: the same scheme as [HistoryPlay.titleKey], so a title
  /// keeps its id whether it was first seen in history or in the library.
  String get titleId {
    final prefix = isMovie ? 'm' : 's';
    if (imdb?.isNotEmpty ?? false) return '$prefix:imdb:$imdb';
    if (tmdb?.isNotEmpty ?? false) return '$prefix:tmdb:$tmdb';
    if (!isMovie && (tvdb?.isNotEmpty ?? false)) return '$prefix:tvdb:$tvdb';
    return '$prefix:title:${title.toLowerCase().trim()}|${year ?? ''}';
  }

  /// The columns [LibraryRef] reads, for a light `SELECT`.
  static const String columns =
      'id, server_id, rating_key, type, title, group_key, year, imdb, tmdb, tvdb, episode_count, '
      'watched_episode_count, view_count';

  static LibraryRef fromRow(Map<String, Object?> r) => LibraryRef(
    rowId: r['id'] as String,
    serverId: r['server_id'] as String,
    ratingKey: r['rating_key'] as String,
    type: r['type'] as String,
    title: r['title'] as String,
    groupKey: r['group_key'] as String,
    year: r['year'] as int?,
    imdb: r['imdb'] as String?,
    tmdb: r['tmdb'] as String?,
    tvdb: r['tvdb'] as String?,
    episodeCount: r['episode_count'] as int?,
    watchedEpisodeCount: r['watched_episode_count'] as int?,
    viewCount: r['view_count'] as int?,
  );
}

List<String> _split(String joined) => joined.isEmpty ? const [] : joined.split('|');

/// Library rows looked up by any id, and by server + rating key.
class LibraryLookup {
  LibraryLookup(Iterable<LibraryRef> rows) {
    for (final t in rows) {
      final p = t.isMovie ? 'm' : 's';
      _byKey.putIfAbsent('${t.serverId}:${t.ratingKey}', () => t);
      for (final (scheme, v) in [('imdb', t.imdb), ('tmdb', t.tmdb), ('tvdb', t.tvdb)]) {
        if (v != null && v.isNotEmpty) _byId.putIfAbsent('$p:$scheme:$v', () => t);
      }
      (_groups[t.groupKey] ??= []).add(t);
    }
  }

  final _byKey = <String, LibraryRef>{};
  final _byId = <String, LibraryRef>{};
  final _groups = <String, List<LibraryRef>>{};
  final _best = <String, LibraryRef>{};

  /// The title a watch is of: its Plex copy first, then any shared id.
  LibraryRef? forPlay(HistoryPlay p) {
    LibraryRef? found;
    if (p.plexServerId != null && p.plexRatingKey != null) found = _byKey['${p.plexServerId}:${p.plexRatingKey}'];
    if (found == null) {
      final prefix = p.isMovie ? 'm' : 's';
      for (final (scheme, v) in [('imdb', p.imdb), ('tmdb', p.tmdb), ('tvdb', p.tvdb)]) {
        if (v != null && v.isNotEmpty) found ??= _byId['$prefix:$scheme:$v'];
      }
    }
    return found == null ? null : best(found);
  }

  /// One copy per title (4K copies and second servers folded).
  Iterable<LibraryRef> get titles => _groups.values.map((copies) => best(copies.first));

  /// The copy that stands for [t]'s title: the one with the most episodes,
  /// then the best watch state.
  LibraryRef best(LibraryRef t) => _best[t.groupKey] ??= (_groups[t.groupKey] ?? [t]).reduce((a, b) {
    final ea = a.episodeCount ?? 0, eb = b.episodeCount ?? 0;
    if (ea != eb) return ea >= eb ? a : b;
    return (a.watchedEpisodeCount ?? a.viewCount ?? 0) >= (b.watchedEpisodeCount ?? b.viewCount ?? 0) ? a : b;
  });
}

/// One watched title: its brain id, its library copy (if any) and every
/// watch of it.
typedef WatchedTitle = ({String id, LibraryRef? ref, List<HistoryPlay> plays});

/// Group watches by title: under the library's id when the title is there,
/// so Plex and Trakt watches carrying different ids land together.
List<WatchedTitle> groupWatches(List<HistoryPlay> plays, LibraryLookup library) {
  final byTitle = <String, List<HistoryPlay>>{};
  final refFor = <String, LibraryRef>{};
  for (final p in plays) {
    final ref = library.forPlay(p);
    final id = ref?.titleId ?? p.titleKey;
    (byTitle[id] ??= []).add(p);
    if (ref != null) refFor.putIfAbsent(id, () => ref);
  }
  return [for (final e in byTitle.entries) (id: e.key, ref: refFor[e.key], plays: e.value)];
}

/// A watched title's profile, from its full library [row] when it has one.
TitleProfile watchedProfile(
  WatchedTitle w, {
  IndexedTitle? row,
  TraktDetails? details,
  TitleExtras extras = const TitleExtras(),
}) => _profile(w.id, row, w.plays, details, extras);

/// An unwatched library title's profile.
TitleProfile libraryProfile(IndexedTitle row, {TitleExtras extras = const TitleExtras()}) =>
    _profile(LibraryRef.of(row).titleId, row, const [], null, extras);

TitleProfile _profile(
  String id,
  IndexedTitle? row,
  List<HistoryPlay> plays,
  TraktDetails? details,
  TitleExtras extras,
) {
  final first = plays.firstOrNull;
  final isMovie = row != null ? row.type == 'movie' : (first?.isMovie ?? true);
  final real = [
    for (final p in plays)
      if (!p.bulk) p.watchedAt,
  ];
  var bulk = plays.length - real.length;

  // Shows: distinct episodes, and those watched again.
  final perEpisode = <String, int>{};
  if (!isMovie) {
    for (final p in plays) {
      perEpisode.update('${p.season ?? 0}x${p.episode ?? 0}', (n) => n + 1, ifAbsent: () => 1);
    }
  }
  var episodesWatched = perEpisode.length;
  if (row != null && !isMovie && (row.watchedEpisodeCount ?? 0) > episodesWatched) {
    episodesWatched = row.watchedEpisodeCount!;
  }
  // Where the undated plays were logged: a Trakt import, or a Plex play
  // with no real date (a bulk-dated mark).
  final bulkVia = <String>{
    for (final p in plays)
      if (p.bulk) p.sources.contains(HistorySource.trakt) ? 'trakt' : 'plexUndated',
  };
  // Plex counts plays it has no dates for; keep them as undated.
  if (row != null && isMovie && (row.viewCount ?? 0) > plays.length) {
    bulk += row.viewCount! - plays.length;
    bulkVia.add('plexUndated');
  }

  final imdb = row?.imdb ?? first?.imdb;
  final tmdb = row?.tmdb ?? first?.tmdb;
  final tvdb = row?.tvdb ?? first?.tvdb;
  final keys = TitleExtras.keysOf(imdb: imdb, tmdb: tmdb, tvdb: isMovie ? null : tvdb, trakt: first?.traktId);
  final rating = keys.map((k) => extras.ratings[k]).nonNulls.firstOrNull;

  return TitleProfile(
    id: id,
    kind: isMovie ? TitleKind.movie : TitleKind.show,
    title: row?.title ?? first?.title ?? '',
    year: row?.year ?? first?.year,
    genres: row != null && row.genres.isNotEmpty
        ? _split(row.genres)
        : (details?.genres.isNotEmpty ?? false)
        ? details!.genres
        : first?.genres ?? const [],
    summary: row?.summary ?? details?.summary,
    tagline: row?.tagline ?? details?.tagline,
    directors: row != null && row.directors.isNotEmpty
        ? _split(row.directors)
        : (details?.directors.isNotEmpty ?? false)
        ? details!.directors
        : first?.directors ?? const [],
    cast: row != null && row.cast.isNotEmpty
        ? _split(row.cast).take(8).toList()
        : (details?.cast.isNotEmpty ?? false)
        ? details!.cast
        : first?.cast ?? const [],
    collections: row == null ? const [] : _split(row.collections),
    studio: row?.studio,
    countries: row != null ? _split(row.countries) : [?details?.country],
    runtimeMinutes: row?.durationMinutes ?? details?.runtime ?? first?.runtimeMinutes,
    audienceRating: row?.audienceRating ?? details?.rating,
    contentRating: row?.contentRating ?? details?.certification,
    serverId: row?.serverId ?? first?.plexServerId,
    ratingKey: row?.ratingKey ?? first?.plexRatingKey,
    thumb: first?.plexThumb,
    posterUrl: first?.posterUrl,
    imdb: imdb,
    tmdb: tmdb,
    tvdb: tvdb,
    inLibrary: row != null,
    watches: real,
    bulkPlays: bulk,
    bulkVia: bulkVia,
    episodesWatched: episodesWatched,
    episodesRewatched: perEpisode.values.where((n) => n > 1).length,
    episodeCount: isMovie ? null : (details?.airedEpisodes ?? row?.episodeCount),
    myRating: rating,
    comfort: keys.any(extras.comfort.contains),
    watchlist: keys.any(extras.watchlist.contains),
  );
}
