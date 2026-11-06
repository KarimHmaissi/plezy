/// Fork (Reel): which trailer or opening a card may play, decided when the
/// card is built and never after it is shown (Reel spec §5). Pure, so the
/// spoiler rules are unit-tested on real-shaped titles.
library;

import 'reel_playback_profile.dart';

/// One Plex extra, as `/library/metadata/{id}/extras` lists it: only the
/// fields the ladder reads.
class PlexExtraClip {
  const PlexExtraClip({
    required this.ratingKey,
    required this.title,
    required this.partKey,
    this.subtype,
    this.extraType,
    this.durationMs,
    this.container,
    this.index = 0,
  });

  final String ratingKey;
  final String title;

  /// `trailer`, `behindTheScenes`, `sceneOrSample`, `deletedScene`, …
  final String? subtype;

  /// Plex's numeric extra type (1 = trailer).
  final int? extraType;
  final int? durationMs;

  /// The part's path (`/services/iva/assets/…/video.mp4?…`), played direct.
  final String partKey;
  final String? container;

  /// Its place in the server's list (Plex lists oldest first).
  final int index;

  bool get isTrailer => subtype?.toLowerCase() == 'trailer' || extraType == 1;

  /// A row from the extras response, or null when it has no playable part.
  static PlexExtraClip? fromJson(Map<String, dynamic> m, int index) {
    final media = m['Media'];
    if (media is! List || media.isEmpty || media.first is! Map) return null;
    final parts = (media.first as Map)['Part'];
    if (parts is! List || parts.isEmpty || parts.first is! Map) return null;
    final key = (parts.first as Map)['key'];
    final ratingKey = m['ratingKey'];
    if (key is! String || key.isEmpty || ratingKey == null) return null;
    return PlexExtraClip(
      ratingKey: '$ratingKey',
      title: (m['title'] as String?)?.trim() ?? '',
      subtype: m['subtype'] as String?,
      extraType: switch (m['extraType']) {
        final int v => v,
        final String v => int.tryParse(v),
        _ => null,
      },
      durationMs: (m['duration'] as num?)?.toInt(),
      partKey: key,
      container: (media.first as Map)['container'] as String? ?? (parts.first as Map)['container'] as String?,
      index: index,
    );
  }

  @override
  String toString() => 'PlexExtraClip($ratingKey, "$title", $subtype)';
}

class ClipFilter {
  const ClipFilter._();

  // Cuts that are not the plain trailer, or say too much.
  static final RegExp _filmExcluded = RegExp(
    r'\b(final|international|4k|basl|alternate|imax|scene|clip|behind|interview|deleted|featurette|'
    r'b-roll|recap|ending|spot|tv spot|sneak peek|red band|first look at|reaction)\b',
    caseSensitive: false,
  );

  // Show extras that name a later season, the end, or are not a trailer.
  static final RegExp _showExcluded = RegExp(
    r'\b(final|ending|date announcement|uncovering|recap|behind|interview|deleted|featurette|'
    r'b-roll|death|finale|spot|reaction|explained)\b',
    caseSensitive: false,
  );

  static final RegExp _laterSeason = RegExp(
    r'\b(season|series|part|volume|vol\.?|chapter|book)\s*(0*[2-9]|[1-9]\d|two|three|four|five|six|seven|eight|nine|ten|ii|iii|iv|v|vi)\b|'
    r'\bs0*([2-9]|[1-9]\d)\b|\b(2nd|3rd|[4-9]th|second|third|fourth|fifth|sixth|final)\s+season\b',
    caseSensitive: false,
  );

  static final RegExp _teaser = RegExp(r'\bteaser\b', caseSensitive: false);
  static final RegExp _plainTrailer = RegExp(r'^(official\s+)?(main\s+)?trailer(\s*(#?1|one))?$', caseSensitive: false);

  /// A film's trailer: a Teaser first, then a plain trailer, then any
  /// trailer that passes the filter. Within each, the one whose length is
  /// closest to [idealMinMs]..[idealMaxMs] wins, then the earliest.
  static PlexExtraClip? filmTrailer(List<PlexExtraClip> extras) {
    final ok = [
      for (final e in extras)
        if (e.isTrailer && !_filmExcluded.hasMatch(e.title) && !_laterSeason.hasMatch(e.title)) e,
    ]..sort(_byLengthThenIndex);
    return ok.where((e) => _teaser.hasMatch(e.title)).firstOrNull ??
        ok.where((e) => _plainTrailer.hasMatch(e.title.trim())).firstOrNull ??
        ok.firstOrNull;
  }

  /// A show's trailer: only when its title is the show's plain name, a
  /// Teaser, an Official Trailer or season 1, and never a later season.
  /// A Teaser first; within that, the length closest to
  /// [idealMinMs]..[idealMaxMs], then the earliest.
  static PlexExtraClip? showTrailer(List<PlexExtraClip> extras, {required String showTitle}) {
    final name = _norm(showTitle);
    bool plain(PlexExtraClip e) {
      final t = _norm(e.title);
      if (t == name) return true;
      final rest = t.startsWith(name) ? t.substring(name.length).trim() : t;
      return RegExp(
        r'^(official\s+)?(teaser|trailer|teaser trailer|main trailer)(\s*(#?1|one))?$|'
        r'^(season|series)\s*(1|one)(\s+(official\s+)?(teaser|trailer))?$|'
        r'^(official\s+)?(teaser|trailer)\s*(season|series)\s*(1|one)$',
      ).hasMatch(rest);
    }

    final ok = [
      for (final e in extras)
        if (e.isTrailer && !_showExcluded.hasMatch(e.title) && !_laterSeason.hasMatch(e.title) && plain(e)) e,
    ]..sort(_byLengthThenIndex);
    return ok.where((e) => _teaser.hasMatch(e.title)).firstOrNull ?? ok.firstOrNull;
  }

  /// The trailer length the tie-break aims for (plan V2-21): 60 to 180 s.
  static const int idealMinMs = 60 * 1000;
  static const int idealMaxMs = 180 * 1000;

  /// How far [durationMs] falls outside [idealMinMs]..[idealMaxMs]; 0 inside
  /// it, and 0 when the length is unknown.
  static int durationGapMs(int? durationMs) {
    if (durationMs == null) return 0;
    if (durationMs < idealMinMs) return idealMinMs - durationMs;
    if (durationMs > idealMaxMs) return durationMs - idealMaxMs;
    return 0;
  }

  /// Orders extras that otherwise rank equally: the length closest to the
  /// ideal window first, a known length in the window before an unknown one,
  /// then the server's order. It only orders; nothing is dropped.
  static int _byLengthThenIndex(PlexExtraClip a, PlexExtraClip b) {
    final gap = durationGapMs(a.durationMs).compareTo(durationGapMs(b.durationMs));
    if (gap != 0) return gap;
    final known = (a.durationMs == null ? 1 : 0).compareTo(b.durationMs == null ? 1 : 0);
    if (known != 0) return known;
    return a.index.compareTo(b.index);
  }

  /// The trailer the TMDB rung would play (plan V2-21 rules, for V2-63) from
  /// a `/movie/{id}/videos` or `/tv/{id}/videos` `results` list: YouTube and
  /// official only, a Trailer before a Teaser, then one in [language] (an
  /// ISO 639-1 code such as `en`) before others, then the earliest
  /// `published_at`. [minSize] (such as 1080), when the caller needs it,
  /// drops anything smaller. The same title rules as the Plex extras apply,
  /// so a later season, a final trailer or a spot is never picked.
  static TmdbVideo? tmdbTrailer(List<dynamic> results, {required String language, bool show = false, int? minSize}) {
    final excluded = show ? _showExcluded : _filmExcluded;
    final lang = language.toLowerCase();
    final ok = <TmdbVideo>[];
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      if (r is! Map) continue;
      final v = TmdbVideo.fromJson(r.cast<String, dynamic>(), i);
      if (v == null || !v.official || v.typeRank == null) continue;
      if (minSize != null && (v.size ?? 0) < minSize) continue;
      if (excluded.hasMatch(v.name) || _laterSeason.hasMatch(v.name)) continue;
      ok.add(v);
    }
    int byDate(TmdbVideo a, TmdbVideo b) {
      final x = a.publishedAt, y = b.publishedAt;
      if (x == null || y == null) return (x == null ? 1 : 0).compareTo(y == null ? 1 : 0);
      return x.compareTo(y);
    }

    ok.sort((a, b) {
      final type = a.typeRank!.compareTo(b.typeRank!);
      if (type != 0) return type;
      final inLang = (a.language == lang ? 0 : 1).compareTo(b.language == lang ? 0 : 1);
      if (inLang != 0) return inLang;
      final date = byDate(a, b);
      if (date != 0) return date;
      return a.index.compareTo(b.index);
    });
    return ok.firstOrNull;
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Season 1's first opening from an AnimeThemes `anime` record, as
  /// [profile] plays it: the best of [openings] by [openingRank], then the
  /// profile's height and file size (plan V2-16, V2-17).
  static AnimeOpening? firstOpening(
    Map<String, dynamic> anime, {
    ReelPlaybackProfile profile = ReelPlaybackProfile.standard,
  }) => profile.pick(openings(anime));

  /// Every file of season 1's first opening: OP with sequence 1 (or the
  /// only OP), from an entry whose episodes start at 1, not a spoiler, not
  /// NSFW, and with no episode footage over it: `overlap` NONE, or TRANS
  /// (kept as a fallback), never OVER or a value this build doesn't know
  /// (D13). Never EDs, never later OPs. Which file plays is the playback
  /// profile's choice, made when the card plays.
  static List<AnimeOpening> openings(Map<String, dynamic> anime) {
    final themes = [
      for (final t in (anime['animethemes'] as List? ?? const []))
        if (t is Map && t['type'] == 'OP') t,
    ];
    if (themes.isEmpty) return const [];
    final op1 = themes.where((t) => (t['sequence'] as int? ?? (themes.length == 1 ? 1 : 0)) == 1).firstOrNull;
    if (op1 == null) return const [];
    final candidates = <AnimeOpening>[];
    for (final entry in (op1['animethemeentries'] as List? ?? const [])) {
      if (entry is! Map) continue;
      if (entry['spoiler'] == true || entry['nsfw'] == true) continue;
      if (!_startsAtOne(entry['episodes'] as String?)) continue;
      for (final v in (entry['videos'] as List? ?? const [])) {
        if (v is! Map) continue;
        final link = v['link'];
        if (link is! String || !link.startsWith('https://')) continue;
        final overlap = overlapOf(v['overlap']);
        if (overlap == null || overlap == OpeningOverlap.over) continue;
        candidates.add(
          AnimeOpening(
            url: link,
            videoId: v['id'] as int?,
            creditless: v['nc'] == true,
            resolution: v['resolution'] as int?,
            sizeBytes: v['size'] as int?,
            song: (op1['song'] as Map?)?['title'] as String?,
            transition: overlap == OpeningOverlap.transition,
            captioned: v['lyrics'] == true || v['subbed'] == true,
            source: v['source'] as String?,
          ),
        );
      }
    }
    return candidates;
  }

  /// An AnimeThemes `overlap` as the GraphQL API spells it (the server's
  /// `VideoOverlap` case names); null for anything else.
  static OpeningOverlap? overlapOf(Object? v) => switch (v) {
    'NONE' => OpeningOverlap.none,
    'TRANS' => OpeningOverlap.transition,
    'OVER' => OpeningOverlap.over,
    _ => null,
  };

  /// An opening file's rank under [captions], lower first, in this order:
  /// no episode footage before a transition; creditless before credited;
  /// with captions off a clean file before one with lyrics or subtitles
  /// burned in, with captions on the reverse; then source BD, WEB, others.
  /// Height and file size come after, from the playback profile.
  static int openingRank({
    required bool transition,
    required bool creditless,
    required bool captioned,
    required String? source,
    required bool captions,
  }) => (transition ? 1000 : 0) + (creditless ? 0 : 100) + (captioned == captions ? 0 : 10) + sourceRank(source);

  /// BD before WEB before any other source (RAW, DVD, VHS, LD) or none.
  static int sourceRank(String? source) => switch (source) {
    'BD' => 0,
    'WEB' => 1,
    _ => 2,
  };

  /// "1-14", "1", "1, 3" start at episode 1; null (unknown) is allowed for a
  /// sole entry since OP1 of season 1 opens episode 1 by definition.
  static bool _startsAtOne(String? episodes) {
    if (episodes == null || episodes.trim().isEmpty) return true;
    final first = RegExp(r'\d+').firstMatch(episodes);
    return first != null && int.parse(first.group(0)!) <= 1;
  }
}

/// How much episode footage an opening's video carries (AnimeThemes
/// `overlap`): none, a transition into or out of the episode, or the episode
/// playing over the opening.
enum OpeningOverlap { none, transition, over }

/// One file of a season-1 opening from AnimeThemes.
class AnimeOpening implements ReelRendition {
  const AnimeOpening({
    required this.url,
    this.videoId,
    this.creditless = false,
    this.resolution,
    this.sizeBytes,
    this.song,
    this.transition = false,
    this.captioned = false,
    this.source,
  });

  final String url;
  final int? videoId;
  final bool creditless;
  final int? resolution;
  @override
  final int? sizeBytes;
  final String? song;

  /// Episode footage transitions into or out of it (`overlap` TRANS): played
  /// only when no file without any is left.
  final bool transition;

  /// Lyrics or dialogue subtitles are burned in.
  final bool captioned;

  /// Where the file came from (`BD`, `WEB`, …), when known.
  final String? source;

  @override
  int? get height => resolution;

  @override
  int rankFor(ReelPlaybackProfile profile) => ClipFilter.openingRank(
    transition: transition,
    creditless: creditless,
    captioned: captioned,
    source: source,
    captions: profile.captions,
  );
}

/// One row of TMDB's videos `results`, as the TMDB rung reads it.
class TmdbVideo {
  const TmdbVideo({
    required this.key,
    required this.name,
    required this.type,
    this.official = false,
    this.language,
    this.size,
    this.publishedAt,
    this.index = 0,
  });

  /// The YouTube video id.
  final String key;
  final String name;

  /// `Trailer`, `Teaser`, `Clip`, `Featurette`, …
  final String type;
  final bool official;

  /// `iso_639_1`, lower-cased; null when blank.
  final String? language;

  /// The tallest upload in lines (360, 720, 1080, …).
  final int? size;
  final DateTime? publishedAt;

  /// Its place in the response.
  final int index;

  /// 0 for a Trailer, 1 for a Teaser, null for any other type.
  int? get typeRank => switch (type) {
    'Trailer' => 0,
    'Teaser' => 1,
    _ => null,
  };

  /// A row from the response, or null when it is not a YouTube video with a
  /// key and a type.
  static TmdbVideo? fromJson(Map<String, dynamic> m, int index) {
    final key = m['key'];
    final type = m['type'];
    if (m['site'] != 'YouTube' || key is! String || key.trim().isEmpty || type is! String) return null;
    final lang = (m['iso_639_1'] as String?)?.trim().toLowerCase();
    final published = m['published_at'];
    return TmdbVideo(
      key: key.trim(),
      name: (m['name'] as String?)?.trim() ?? '',
      type: type,
      official: m['official'] == true,
      language: lang == null || lang.isEmpty ? null : lang,
      size: (m['size'] as num?)?.toInt(),
      publishedAt: published is String ? DateTime.tryParse(published) : null,
      index: index,
    );
  }

  @override
  String toString() => 'TmdbVideo($key, "$name", $type)';
}
