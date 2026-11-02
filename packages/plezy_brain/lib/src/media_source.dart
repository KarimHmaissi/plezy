/// A movie or episode the brain can read dialogue for.
class MediaLeaf {
  const MediaLeaf({
    required this.id,
    required this.type,
    this.show,
    this.season,
    this.episode,
    this.title,
    this.year,
    this.durationMs,
  });

  /// The server's id for it (a Plex rating key).
  final String id;

  /// `movie` or `episode`.
  final String type;
  final String? show;
  final int? season;
  final int? episode;
  final String? title;
  final int? year;
  final int? durationMs;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'show': ?show,
    'season': ?season,
    'episode': ?episode,
    'title': ?title,
    'year': ?year,
    'durationMs': ?durationMs,
  };

  static MediaLeaf fromJson(Map<String, Object?> j) => MediaLeaf(
    id: j['id'] as String,
    type: j['type'] as String? ?? 'movie',
    show: j['show'] as String?,
    season: j['season'] as int?,
    episode: j['episode'] as int?,
    title: j['title'] as String?,
    year: j['year'] as int?,
    durationMs: j['durationMs'] as int?,
  );
}

/// A subtitle track of a leaf.
class SubtitleStream {
  const SubtitleStream({
    required this.language,
    required this.codec,
    this.sidecarKey,
    this.partKey,
    this.index,
    this.forced = false,
    this.hearingImpaired = false,
  });

  /// ISO 639 code as the server reports it (`en`, `eng`).
  final String language;
  final String codec;

  /// Server path of a separate subtitle file; null when embedded.
  final String? sidecarKey;

  /// The media part holding an embedded track, and its stream index there.
  final String? partKey;
  final int? index;
  final bool forced;
  final bool hearingImpaired;

  bool get isSidecar => sidecarKey != null && sidecarKey!.isNotEmpty;
}

/// Everything the brain needs from a media server. The host app implements
/// it on its own client, so credentials stay with the app; a headless
/// service can implement it with its own sign-in.
abstract interface class MediaSource {
  /// The movie or episode [id], or every episode under a show or season.
  Future<List<MediaLeaf>> leaves(String id);

  /// Subtitle tracks of a movie or episode.
  Future<List<SubtitleStream>> subtitleStreams(String id);

  /// The text of a separate subtitle file, as SRT.
  Future<String> fetchSidecar(SubtitleStream stream);

  /// A URL a local tool (ffmpeg) can read [partKey] from. Carries
  /// credentials: never log or store it.
  String? partUrl(String partKey);
}
