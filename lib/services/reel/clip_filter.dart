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

  /// A film's trailer: a Teaser first, then the earliest plain trailer,
  /// then the earliest trailer that passes the filter.
  static PlexExtraClip? filmTrailer(List<PlexExtraClip> extras) {
    final ok = [
      for (final e in extras)
        if (e.isTrailer && !_filmExcluded.hasMatch(e.title) && !_laterSeason.hasMatch(e.title)) e,
    ]..sort((a, b) => a.index.compareTo(b.index));
    return ok.where((e) => _teaser.hasMatch(e.title)).firstOrNull ??
        ok.where((e) => _plainTrailer.hasMatch(e.title.trim())).firstOrNull ??
        ok.firstOrNull;
  }

  /// A show's trailer: only when its title is the show's plain name, a
  /// Teaser, an Official Trailer or season 1, and never a later season.
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
    ]..sort((a, b) => a.index.compareTo(b.index));
    return ok.where((e) => _teaser.hasMatch(e.title)).firstOrNull ?? ok.firstOrNull;
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Season 1's first opening from an AnimeThemes `anime` record, as
  /// [profile] plays it: the best of [openings] by its rank (creditless
  /// first), then the profile's height and file size (plan V2-16).
  static AnimeOpening? firstOpening(
    Map<String, dynamic> anime, {
    ReelPlaybackProfile profile = ReelPlaybackProfile.standard,
  }) => profile.pick(openings(anime));

  /// Every file of season 1's first opening: OP with sequence 1 (or the
  /// only OP), from an entry whose episodes start at 1, not a spoiler, not
  /// NSFW. Never EDs, never later OPs. Which file plays is the playback
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
        candidates.add(
          AnimeOpening(
            url: link,
            videoId: v['id'] as int?,
            creditless: v['nc'] == true,
            resolution: v['resolution'] as int?,
            sizeBytes: v['size'] as int?,
            song: (op1['song'] as Map?)?['title'] as String?,
          ),
        );
      }
    }
    return candidates;
  }

  /// "1-14", "1", "1, 3" start at episode 1; null (unknown) is allowed for a
  /// sole entry since OP1 of season 1 opens episode 1 by definition.
  static bool _startsAtOne(String? episodes) {
    if (episodes == null || episodes.trim().isEmpty) return true;
    final first = RegExp(r'\d+').firstMatch(episodes);
    return first != null && int.parse(first.group(0)!) <= 1;
  }
}

/// One file of a season-1 opening from AnimeThemes.
class AnimeOpening implements ReelRendition {
  const AnimeOpening({
    required this.url,
    this.videoId,
    this.creditless = false,
    this.resolution,
    this.sizeBytes,
    this.song,
  });

  final String url;
  final int? videoId;
  final bool creditless;
  final int? resolution;
  @override
  final int? sizeBytes;
  final String? song;

  @override
  int? get height => resolution;

  /// Creditless before credited.
  @override
  int get rank => creditless ? 0 : 1;
}
