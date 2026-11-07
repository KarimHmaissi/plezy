import '../../media/media_item.dart';
import '../../media/media_kind.dart';

/// Continue Watching split into the two Home rows.
typedef ContinueWatchingSplit = ({List<MediaItem> fresh, List<MediaItem> pickBackUp});

/// Below this much progress a start counts as accidental and is hidden.
const Duration continueWatchingAccidentalStart = Duration(minutes: 3);

/// A film this far through counts as finished and is hidden.
const double continueWatchingFilmFinished = 0.9;

/// Split the merged Continue Watching items (already most-recent first) into
/// "Continue Watching" — touched within [staleAfter] — and "Pick back up".
///
/// - Age is the item's `lastViewedAt` (else `addedAt`; an item with neither
///   stays fresh). For a next-up episode Plex reports the
///   show's last-watched time there, so a show is aged by when it was last
///   watched, not by the unwatched episode's add date.
/// - A next-up episode added after the show was last watched is a new episode
///   of a show the viewer had caught up on: it stays fresh regardless of age.
/// - Accidental starts (under [continueWatchingAccidentalStart] in) and films
///   past [continueWatchingFilmFinished] are dropped. Hidden client-side only;
///   nothing is marked watched.
/// - Items last touched more than [maxAge] ago are dropped entirely (a new
///   episode of a caught-up show is still kept).
/// - Episodes of shows in [excludedShowTitles] (normalised with
///   [normalizeShowTitle]) are dropped — the Comfort tab covers those.
///
/// Order within each row is preserved.
ContinueWatchingSplit classifyContinueWatching(
  List<MediaItem> items, {
  required DateTime now,
  Duration staleAfter = const Duration(days: 30),
  Duration maxAge = const Duration(days: 365),
  Set<String> excludedShowTitles = const {},
}) {
  final fresh = <MediaItem>[];
  final pickBackUp = <MediaItem>[];
  final cutoff = now.subtract(staleAfter).millisecondsSinceEpoch ~/ 1000;
  final oldest = now.subtract(maxAge).millisecondsSinceEpoch ~/ 1000;
  for (final item in items) {
    if (excludedShowTitles.isNotEmpty &&
        item.kind == MediaKind.episode &&
        excludedShowTitles.contains(normalizeShowTitle(item.grandparentTitle))) {
      continue;
    }
    final offset = item.viewOffsetMs;
    final started = offset != null && offset > 0;
    if (started && offset < continueWatchingAccidentalStart.inMilliseconds) continue;
    final duration = item.durationMs;
    if (started && item.kind == MediaKind.movie && duration != null && duration > 0) {
      if (offset / duration >= continueWatchingFilmFinished) continue;
    }
    final lastViewed = item.lastViewedAt;
    final added = item.addedAt;
    final isNewEpisode =
        item.kind == MediaKind.episode && !started && added != null && lastViewed != null && added > lastViewed;
    final activity = lastViewed ?? added;
    if (!isNewEpisode && activity != null && activity < oldest) continue;
    // No timestamps at all is no evidence of age: keep it in the main row.
    if (isNewEpisode || activity == null || activity >= cutoff) {
      fresh.add(item);
    } else {
      pickBackUp.add(item);
    }
  }
  return (fresh: fresh, pickBackUp: pickBackUp);
}

/// Compare show titles across sources: case, punctuation and a trailing
/// "(2009)" year disambiguator are ignored ("Marsh Lane (2009)" == "Marsh Lane").
String normalizeShowTitle(String? title) {
  if (title == null) return '';
  return title.toLowerCase().replaceAll(RegExp(r'\s*\(\d{4}\)\s*$'), '').replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

/// Comfort-show episodes the user is part-way through, newest first: the
/// rows Home's Continue Watching leaves out (see [classifyContinueWatching]'s
/// `excludedShowTitles`). Accidental starts and nearly finished episodes are
/// dropped, as in Continue Watching.
List<MediaItem> comfortCarryOn(Iterable<MediaItem> onDeck, Set<String> comfortTitles) {
  if (comfortTitles.isEmpty) return const [];
  bool partWatched(MediaItem item) {
    final offset = item.viewOffsetMs;
    final duration = item.durationMs;
    if (offset == null || duration == null || duration <= 0) return false;
    return offset >= continueWatchingAccidentalStart.inMilliseconds && offset / duration < continueWatchingFilmFinished;
  }

  final items = [
    for (final item in onDeck)
      if (item.kind == MediaKind.episode &&
          comfortTitles.contains(normalizeShowTitle(item.grandparentTitle)) &&
          partWatched(item))
        item,
  ];
  items.sort((a, b) => (b.lastViewedAt ?? 0).compareTo(a.lastViewedAt ?? 0));
  return items;
}
