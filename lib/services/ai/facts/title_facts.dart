/// Fork: Straight Facts, the honest per-title facts every recommender
/// surface (Ask, Tonight, AI rows, the Reel) reads. These types are the
/// frozen interfaces of recommender v2 §3: the Reel builds against them,
/// and later phases (the IMDb dataset, TMDB, the pick ledger) fill them in
/// without changing their shape.
library;

import '../../../media/media_rating.dart';
import 'seen_state.dart';

export 'seen_state.dart';

/// A brain `TitleProfile.id` (`m:imdb:tt…`, `s:tvdb:…`): the same title
/// across servers, 4K copies and devices.
typedef TitleId = String;

/// One title, as every surface names it.
class TitleRef {
  const TitleRef({required this.id, required this.groupKey, this.globalKey});

  final TitleId id;

  /// The library index's `group_key`: every copy of the title.
  final String groupKey;

  /// One playable copy, `serverId:ratingKey` (the index row id), when the
  /// surface has one.
  final String? globalKey;

  @override
  bool operator ==(Object other) => other is TitleRef && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'TitleRef($id)';
}

/// What a title is, as far as the facts go. Scores carry their real
/// source: nothing is called IMDb unless it came from IMDb.
class TitleFacts {
  const TitleFacts({
    required this.ref,
    required this.seen,
    this.imdb,
    this.imdbVotes,
    this.rtCritic,
    this.rtAudience,
    this.tmdb,
    this.audience,
    this.certificate,
    this.inKidsLibrary = false,
    this.kidsLibraryOnly = false,
    this.genres = const [],
    this.keywords = const [],
    this.showStatus,
    this.runtimeMinutes,
    this.episodes,
    this.seasons,
    this.ledger,
  });

  final TitleRef ref;

  /// IMDb rating 0-10 and its vote count.
  final double? imdb;
  final int? imdbVotes;

  /// Rotten Tomatoes critic and audience scores, 0-10 (shown as percent).
  final double? rtCritic;
  final double? rtAudience;

  /// TMDB user score, 0-10.
  final double? tmdb;

  /// A Plex audience score whose source isn't known (the index keeps the
  /// number, not where it came from). Shown as a bare `★`, never labelled.
  final double? audience;

  /// The certificate ("15", "PG-13", "TV-MA").
  final String? certificate;

  /// Any copy of the title sits in a Kids library (EXISTS over its copies).
  final bool inKidsLibrary;

  /// Every copy sits in a Kids library (ALL over its copies).
  final bool kidsLibraryOnly;
  final List<String> genres;
  final List<String> keywords;

  /// A show's status ("Ended", "Returning Series"), once TMDB fills it.
  final String? showStatus;

  /// A film's length, or a show's episode length.
  final int? runtimeMinutes;

  /// Shows: episodes and seasons on the servers.
  final int? episodes;
  final int? seasons;
  final SeenState seen;

  /// What surfaces did with the title lately; null until the pick ledger
  /// lands.
  final LedgerSummary? ledger;

  bool get isShow => ref.id.startsWith('s:');

  /// Labelled scores from a title's rating list ([MediaItem.ratings]),
  /// keeping anything already set here.
  TitleFacts withRatings(List<MediaRatingSource>? ratings) {
    if (ratings == null || ratings.isEmpty) return this;
    MediaRatingSource? of(String source) => ratings.where((r) => r.source == source).firstOrNull;
    final i = of('imdb');
    return copyWith(
      imdb: imdb ?? i?.value,
      imdbVotes: imdbVotes ?? i?.votes,
      rtCritic: rtCritic ?? of('rottenTomatoesCritic')?.value,
      rtAudience: rtAudience ?? of('rottenTomatoesAudience')?.value,
      tmdb: tmdb ?? of('tmdb')?.value,
    );
  }

  TitleFacts copyWith({
    double? imdb,
    int? imdbVotes,
    double? rtCritic,
    double? rtAudience,
    double? tmdb,
    SeenState? seen,
    LedgerSummary? ledger,
  }) => TitleFacts(
    ref: ref,
    seen: seen ?? this.seen,
    imdb: imdb ?? this.imdb,
    imdbVotes: imdbVotes ?? this.imdbVotes,
    rtCritic: rtCritic ?? this.rtCritic,
    rtAudience: rtAudience ?? this.rtAudience,
    tmdb: tmdb ?? this.tmdb,
    audience: audience,
    certificate: certificate,
    inKidsLibrary: inKidsLibrary,
    kidsLibraryOnly: kidsLibraryOnly,
    genres: genres,
    keywords: keywords,
    showStatus: showStatus,
    runtimeMinutes: runtimeMinutes,
    episodes: episodes,
    seasons: seasons,
    ledger: ledger ?? this.ledger,
  );

  /// The one score a card shows: IMDb when known, else the best labelled
  /// score, else the unlabelled Plex audience score as a bare star.
  /// "IMDb 8.5 (220k)", compact "IMDb 8.5"; "RT 77%"; "TMDB 8.2"; "★ 8.3".
  String? cardLine({bool compact = false}) {
    if (imdb != null) {
      final votes = imdbVotes;
      return compact || votes == null ? 'IMDb ${_one(imdb!)}' : 'IMDb ${_one(imdb!)} (${compactCount(votes)})';
    }
    if (rtAudience != null) return 'RT audience ${_percent(rtAudience!)}';
    if (tmdb != null) return 'TMDB ${_one(tmdb!)}';
    if (rtCritic != null) return 'RT ${_percent(rtCritic!)}';
    if (audience != null) return '★ ${_one(audience!)}';
    return null;
  }

  /// A card's length fact: "1h 58m" for a film, "62 episodes" for a show.
  String? lengthLine() {
    if (isShow) {
      final n = episodes;
      return n == null || n == 0 ? null : (n == 1 ? '1 episode' : '$n episodes');
    }
    final m = runtimeMinutes;
    if (m == null || m <= 0) return null;
    return m < 60 ? '${m}m' : '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }

  /// Every fact, labelled, for a model prompt:
  /// "IMDb 8.5 (220k) · RT 77% · 15 · also in Kids library · watched Oct 2026".
  String modelLine() {
    final parts = <String>[
      if (imdb != null) imdbVotes == null ? 'IMDb ${_one(imdb!)}' : 'IMDb ${_one(imdb!)} (${compactCount(imdbVotes!)})',
      if (rtCritic != null) 'RT ${_percent(rtCritic!)}',
      if (rtAudience != null) 'RT audience ${_percent(rtAudience!)}',
      if (tmdb != null) 'TMDB ${_one(tmdb!)}',
      if (imdb == null && rtCritic == null && rtAudience == null && tmdb == null && audience != null)
        'Plex audience ${_one(audience!)} (source unknown)',
      ?certificate,
      if (kidsLibraryOnly) 'Kids library only' else if (inKidsLibrary) 'also in Kids library',
      if (showStatus != null) showStatus!.toLowerCase(),
      seen.line(),
      ?ledger?.factLine(),
    ];
    return parts.join(' · ');
  }

  static String _one(double v) => v.toStringAsFixed(1);
  static String _percent(double v) => '${(v * 10).round()}%';

  /// 950 → "950", 12_400 → "12k", 1_250_000 → "1.3M".
  static String compactCount(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n / 1000).round()}k';
    final m = n / 1000000;
    return '${m >= 10 ? m.round() : m.toStringAsFixed(1)}M';
  }
}

/// Where surfaces get [TitleFacts].
abstract interface class TitleFactsSource {
  /// Facts for [refs], in one batch. Titles the source can't find are left
  /// out of the map.
  Future<Map<TitleId, TitleFacts>> load(Iterable<TitleRef> refs);

  /// Facts already loaded for a copy (`serverId:ratingKey`), for a card's
  /// synchronous `build()`. Null until a [load] has covered it.
  TitleFacts? peek(String globalKey);
}

// ---- Videos: a clip or trailer for each card -------------------------------

enum VideoKind { trailer, teaser, clip, featurette, behindTheScenes }

enum VideoOrigin { plexExtra, tmdbYouTube }

/// One video about a title (never episode footage).
class TitleVideo {
  const TitleVideo({
    required this.kind,
    required this.origin,
    required this.title,
    this.plexKey,
    this.serverId,
    this.youtubeKey,
    this.seconds,
    this.language,
  });

  final VideoKind kind;
  final VideoOrigin origin;

  /// The video's own title ("Official Trailer", "Season 2 Teaser"), which
  /// the spoiler filter reads.
  final String title;

  /// Plex extras: the extra's metadata key and its server.
  final String? plexKey;
  final String? serverId;

  /// TMDB videos: the YouTube key.
  final String? youtubeKey;
  final int? seconds;
  final String? language;

  @override
  String toString() => 'TitleVideo(${kind.name}, ${origin.name}, "$title")';
}

/// Videos for one title, fetched on demand (never a bulk fetch).
abstract interface class TitleMediaSource {
  Future<List<TitleVideo>> videos(TitleRef ref);
}

// ---- The pick ledger: what surfaces showed, and what happened next ---------

enum PickSurface { ask, tonight, aiRow, suggested, moreLikeThis, dice, reel, arc /* reserved */ }

enum PickAction { shown, opened, played, kept, notForMe, saved, sampled }

class PickEvent {
  const PickEvent({
    required this.id,
    required this.surface,
    required this.action,
    required this.at,
    this.context,
    this.position,
    this.seconds,
    this.weight = 1.0,
  });

  final TitleId id;
  final PickSurface surface;
  final PickAction action;
  final DateTime at;

  /// The ask, deck or row it was shown in.
  final String? context;
  final int? position;

  /// [PickAction.sampled]: seconds watched.
  final int? seconds;
  final double weight;
}

enum PickOutcome { pending, took, kept, neutral }

class LedgerSummary {
  const LedgerSummary({
    this.shownWeight = 0,
    this.timesShown = 0,
    this.lastShown,
    this.surfaces = const {},
    this.outcome = PickOutcome.pending,
    this.notForMeAt,
    this.now,
  });

  /// Decayed impression weight (halves every 21 days).
  final double shownWeight;
  final int timesShown;
  final DateTime? lastShown;
  final Set<PickSurface> surfaces;
  final PickOutcome outcome;
  final DateTime? notForMeAt;

  /// The clock the summary was built against.
  final DateTime? now;

  /// Passed on within the last 90 days.
  bool get resting {
    final at = notForMeAt;
    if (at == null) return false;
    return (now ?? DateTime.now()).difference(at) < const Duration(days: 90);
  }

  /// A soft fact for the model, or null when there is nothing to say.
  /// "shown 3× lately, not played yet" / "passed on in Aug".
  String? factLine() {
    final at = notForMeAt;
    if (at != null) {
      final age = (now ?? DateTime.now()).difference(at);
      if (age < const Duration(days: 180)) return 'passed on in ${SeenState.monthName(at.month)}';
    }
    if (timesShown == 0) return null;
    return switch (outcome) {
      PickOutcome.took || PickOutcome.kept => null,
      _ => 'shown $timesShown× lately, not played yet',
    };
  }
}

abstract interface class PickLedger {
  Future<void> record(List<PickEvent> events);
  Future<Map<TitleId, LedgerSummary>> summaries(Iterable<TitleId> ids, {DateTime? now});

  /// Titles shown on [surfaces] within [window] (Tonight's 5-day rotation).
  Future<Set<TitleId>> shownWithin(Duration window, {Iterable<PickSurface>? surfaces, DateTime? now});
  Future<String> promptFacts({DateTime? now, int maxLines = 40});

  /// Titles resting after Not for me (code-built pools only).
  Future<Set<TitleId>> resting({DateTime? now});
}
