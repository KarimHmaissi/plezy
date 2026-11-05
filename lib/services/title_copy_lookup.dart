import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/title_copies.dart';
import '../utils/external_ids.dart';
import '../utils/media_server_http_client.dart';
import 'data_aggregation_service.dart';

/// Every copy of one title across the user's servers: the movie, or the
/// episode by its show and numbers, that a card or a stalled stream names.
///
/// A thin, player-free wrapper over
/// [DataAggregationService.findTitleCopiesAcrossServers], so The Reel's "Play
/// this" and Best Copy's rescue ask the same way. Each call is one per-title
/// lookup per online server under that method's deadline; it opens no stream
/// and never walks a library.
class TitleCopies {
  TitleCopies(this._find);

  /// Copies found through [service], the app's aggregation service.
  TitleCopies.from(DataAggregationService service) : this(service.findTitleCopiesAcrossServers);

  final Future<LibraryLookupResult> Function(TitleQuery query, {AbortController? abort}) _find;

  /// The copies of a movie, by its catalogue [ids] or Plex [plexGuid] first,
  /// else by [title] and [year].
  Future<LibraryLookupResult> movie({
    String title = '',
    int? year,
    ExternalIds ids = const ExternalIds(),
    String? plexGuid,
    AbortController? abort,
  }) => _find(
    TitleQuery.movie(title: title, year: year, ids: ids, plexGuid: plexGuid),
    abort: abort,
  );

  /// The copies of [episode] in [season] of a show, found through the show's
  /// [showIds] or [showPlexGuid] first, else its [showTitle] and [showYear].
  /// The episode's own [ids], when known, drop a numbered match that names a
  /// different episode.
  Future<LibraryLookupResult> episode({
    String showTitle = '',
    int? showYear,
    ExternalIds showIds = const ExternalIds(),
    String? showPlexGuid,
    required int season,
    required int episode,
    ExternalIds ids = const ExternalIds(),
    AbortController? abort,
  }) => _find(
    TitleQuery.episode(
      showTitle: showTitle,
      showYear: showYear,
      showIds: showIds,
      showPlexGuid: showPlexGuid,
      season: season,
      episode: episode,
      ids: ids,
    ),
    abort: abort,
  );

  /// The copies of a library [item] (a movie, or an episode with its numbers),
  /// on every server including its own. Null, with nothing asked, for any
  /// other kind and for an episode without its season and episode numbers.
  Future<LibraryLookupResult>? forItem(
    MediaItem item, {
    ExternalIds ids = const ExternalIds(),
    ExternalIds showIds = const ExternalIds(),
    AbortController? abort,
  }) {
    final query = queryFor(item, ids: ids, showIds: showIds);
    return query == null ? null : _find(query, abort: abort);
  }

  /// What [forItem] looks for. A movie goes by its Plex guid, title and year;
  /// an episode by its show's title and its own numbers (an episode row does
  /// not carry the show's guid).
  static TitleQuery? queryFor(
    MediaItem item, {
    ExternalIds ids = const ExternalIds(),
    ExternalIds showIds = const ExternalIds(),
  }) {
    switch (item.kind) {
      case MediaKind.movie:
        return TitleQuery.movie(title: item.title ?? '', year: item.year, ids: ids, plexGuid: _plexGuid(item.guid));
      case MediaKind.episode:
        final season = item.parentIndex;
        final episode = item.index;
        if (season == null || episode == null) return null;
        return TitleQuery.episode(
          showTitle: item.grandparentTitle ?? '',
          showIds: showIds,
          season: season,
          episode: episode,
          ids: ids,
          title: item.title ?? '',
        );
      default:
        return null;
    }
  }

  static String? _plexGuid(String? guid) => guid != null && guid.startsWith('plex://') ? guid : null;
}

extension TitleCopiesOutcome on LibraryLookupResult {
  /// Whether every expected server answered. When false, an empty or short
  /// [LibraryLookupResult.items] is not proof the title is missing: a failed,
  /// cancelled or offline server may hold it.
  bool get isComplete => failedServerIds.isEmpty && cancelledServerIds.isEmpty && unqueriedServerIds.isEmpty;
}
