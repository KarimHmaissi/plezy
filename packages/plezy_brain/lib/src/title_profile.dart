/// Films and shows as the brain knows them: what a title is, and how the
/// user has watched it.
library;

enum TitleKind { movie, show }

/// How far the user got with a show.
enum ShowProgress {
  /// Not started (or not a show).
  none,

  /// Not caught up, watched in the last [TitleProfile.pausedAfter].
  inProgress,

  /// Not caught up, last watched between [TitleProfile.pausedAfter] and
  /// [TitleProfile.droppedAfter] ago.
  paused,

  /// Not caught up, untouched for [TitleProfile.droppedAfter], after a real
  /// go at it (at least [TitleProfile.droppedMinEpisodes] episodes or a
  /// tenth of the show).
  dropped,

  /// Tried an episode or two, long ago.
  sampled,

  /// Caught up: (nearly) every episode there is so far.
  finished,

  /// Started, but the number of episodes isn't known.
  unknown,
}

/// One film or show: its details (from the library, else the tracker) and
/// the user's watching of it. The host builds these; the brain indexes and
/// queries them.
class TitleProfile {
  TitleProfile({
    required this.id,
    required this.kind,
    required this.title,
    this.year,
    this.genres = const [],
    this.summary,
    this.plot,
    this.tagline,
    this.directors = const [],
    this.cast = const [],
    this.collections = const [],
    this.studio,
    this.countries = const [],
    this.runtimeMinutes,
    this.audienceRating,
    this.contentRating,
    this.serverId,
    this.ratingKey,
    this.thumb,
    this.posterUrl,
    this.imdb,
    this.tmdb,
    this.tvdb,
    this.inLibrary = false,
    List<DateTime> watches = const [],
    this.bulkPlays = 0,
    this.episodesWatched = 0,
    this.episodesRewatched = 0,
    this.episodeCount,
    this.myRating,
    this.comfort = false,
    this.watchlist = false,
  }) : watches = [...watches]..sort();

  /// Stable across hosts and rebuilds: `m:imdb:tt…`, `s:tvdb:…`, or the
  /// host's own key when the title has no external id.
  final String id;
  final TitleKind kind;
  final String title;
  final int? year;
  final List<String> genres;
  final String? summary;

  /// A fuller account of what happens (a Wikipedia plot or premise), when
  /// the host has one.
  final String? plot;
  final String? tagline;
  final List<String> directors;
  final List<String> cast;

  /// Franchises and collections ("Marvel Cinematic Universe").
  final List<String> collections;
  final String? studio;
  final List<String> countries;

  /// A film's length, or a show's episode length.
  final int? runtimeMinutes;

  /// Audience rating, 0-10.
  final double? audienceRating;
  final String? contentRating;

  /// Where to play it: a server and its id there.
  final String? serverId;
  final String? ratingKey;

  /// Server image path, or an absolute poster URL.
  final String? thumb;
  final String? posterUrl;
  final String? imdb;
  final String? tmdb;
  final String? tvdb;

  /// On one of the user's servers.
  final bool inLibrary;

  /// Real viewing dates, oldest first: each watch of a film, each episode
  /// watch of a show. Imports and "mark as watched" are in [bulkPlays].
  final List<DateTime> watches;
  final int bulkPlays;

  /// Shows: distinct episodes watched, and how many of those were watched
  /// more than once.
  final int episodesWatched;
  final int episodesRewatched;
  final int? episodeCount;

  /// The user's own rating, 1-10.
  final int? myRating;
  final bool comfort;
  final bool watchlist;

  bool get isMovie => kind == TitleKind.movie;
  int get plays => watches.length + bulkPlays;
  bool get watched => plays > 0;
  DateTime? get firstWatched => watches.isEmpty ? null : watches.first;
  DateTime? get lastWatched => watches.isEmpty ? null : watches.last;

  /// A film seen more than once, or a show with episodes seen again.
  bool get rewatched => isMovie ? plays > 1 : episodesRewatched > 0;

  /// Not caught up and not watched for this long: paused, then dropped.
  static const Duration pausedAfter = Duration(days: 60);
  static const Duration droppedAfter = Duration(days: 180);
  static const int droppedMinEpisodes = 3;

  ShowProgress progress(DateTime now) {
    if (isMovie || episodesWatched == 0) return ShowProgress.none;
    final total = episodeCount;
    if (total == null || total == 0) return ShowProgress.unknown;
    if (episodesWatched >= total * 0.9) return ShowProgress.finished;
    final last = lastWatched;
    final idle = last == null ? null : now.difference(last);
    if (idle != null && idle <= pausedAfter) return ShowProgress.inProgress;
    if (idle != null && idle <= droppedAfter) return ShowProgress.paused;
    final realGo = episodesWatched >= droppedMinEpisodes || episodesWatched >= total * 0.1;
    return realGo ? ShowProgress.dropped : ShowProgress.sampled;
  }

  /// What the title is, for embedding: no watch data, so similar titles sit
  /// together whatever the user did with them.
  String get embedText {
    final b = StringBuffer('$title${year == null ? '' : ' ($year)'}. ${isMovie ? 'Film' : 'TV series'}.');
    if (genres.isNotEmpty) b.write(' Genres: ${genres.join(', ')}.');
    if (collections.isNotEmpty) b.write(' Part of: ${collections.take(3).join(', ')}.');
    if (directors.isNotEmpty) b.write(' Directed by ${directors.take(2).join(', ')}.');
    if (cast.isNotEmpty) b.write(' Starring ${cast.take(5).join(', ')}.');
    if (countries.isNotEmpty) b.write(' ${countries.take(2).join(', ')}.');
    if (tagline != null && tagline!.isNotEmpty) b.write(' $tagline');
    if (summary != null && summary!.isNotEmpty) b.write(' $summary');
    // The plot's opening fills what the model can read (512 tokens).
    if (plot != null && plot!.isNotEmpty) b.write(' ${plot!.length > 1600 ? plot!.substring(0, 1600) : plot}');
    return b.toString();
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'k': kind.name,
    't': title,
    'y': ?year,
    if (genres.isNotEmpty) 'g': genres,
    's': ?summary,
    'pl': ?plot,
    'tl': ?tagline,
    if (directors.isNotEmpty) 'd': directors,
    if (cast.isNotEmpty) 'c': cast,
    if (collections.isNotEmpty) 'col': collections,
    'st': ?studio,
    if (countries.isNotEmpty) 'co': countries,
    'rt': ?runtimeMinutes,
    'ar': ?audienceRating,
    'cr': ?contentRating,
    'sv': ?serverId,
    'rk': ?ratingKey,
    'th': ?thumb,
    'pu': ?posterUrl,
    'imdb': ?imdb,
    'tmdb': ?tmdb,
    'tvdb': ?tvdb,
    if (inLibrary) 'lib': true,
    if (watches.isNotEmpty) 'w': [for (final w in watches) w.millisecondsSinceEpoch],
    if (bulkPlays > 0) 'bp': bulkPlays,
    if (episodesWatched > 0) 'ew': episodesWatched,
    if (episodesRewatched > 0) 'er': episodesRewatched,
    'ec': ?episodeCount,
    'mr': ?myRating,
    if (comfort) 'cf': true,
    if (watchlist) 'wl': true,
  };

  static TitleProfile fromJson(Map<String, Object?> j) {
    List<String> strings(Object? v) => v is List ? [for (final s in v) '$s'] : const [];
    return TitleProfile(
      id: j['id'] as String,
      kind: j['k'] == 'show' ? TitleKind.show : TitleKind.movie,
      title: j['t'] as String? ?? '',
      year: j['y'] as int?,
      genres: strings(j['g']),
      summary: j['s'] as String?,
      plot: j['pl'] as String?,
      tagline: j['tl'] as String?,
      directors: strings(j['d']),
      cast: strings(j['c']),
      collections: strings(j['col']),
      studio: j['st'] as String?,
      countries: strings(j['co']),
      runtimeMinutes: j['rt'] as int?,
      audienceRating: (j['ar'] as num?)?.toDouble(),
      contentRating: j['cr'] as String?,
      serverId: j['sv'] as String?,
      ratingKey: j['rk'] as String?,
      thumb: j['th'] as String?,
      posterUrl: j['pu'] as String?,
      imdb: j['imdb'] as String?,
      tmdb: j['tmdb'] as String?,
      tvdb: j['tvdb'] as String?,
      inLibrary: j['lib'] == true,
      watches: [
        for (final w in (j['w'] as List? ?? const [])) DateTime.fromMillisecondsSinceEpoch(w as int, isUtc: true),
      ],
      bulkPlays: j['bp'] as int? ?? 0,
      episodesWatched: j['ew'] as int? ?? 0,
      episodesRewatched: j['er'] as int? ?? 0,
      episodeCount: j['ec'] as int?,
      myRating: j['mr'] as int?,
      comfort: j['cf'] == true,
      watchlist: j['wl'] == true,
    );
  }
}
