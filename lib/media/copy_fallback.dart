import 'media_item.dart';
import 'media_item_merge.dart';
import 'media_version.dart';

/// Fork: the most copies an open tries after the one it was asked to play.
/// The server's own silent switch to another version of a missing file counts
/// as one of them: the viewer waits on it all the same.
const int maxCopyFallbackAttempts = 3;

/// Why an open moved on to another copy. [name] is what the `[CopyFallback]`
/// log line prints, so it stays short and carries no server detail.
enum CopyFallbackReason {
  /// The server answered the stream with HTTP 503 for the whole open window.
  http503,

  /// The server could not read the file (HTTP 404).
  http404,

  /// The server said the file is gone (HTTP 410).
  http410,

  /// The server's file check (`checkFiles=1`) flagged the version as missing
  /// or unreadable, so the server's metadata pointed the open elsewhere.
  missing,

  /// The open failed with no status: the resolve threw, or the player could
  /// not open the source.
  openFailed,

  /// The open stopped making progress before the first frame.
  timedOut,

  /// The player could not set up a decoder or output for this file.
  streamInit,

  /// This copy failed to play recently, so the open skipped it.
  remembered,
}

/// One file to try: [copy] (a title on one server and library) and its
/// version at [versionIndex]. A copy whose versions are unknown stands for
/// itself, at index 0.
class CopySource {
  const CopySource(this.copy, this.versionIndex);

  final MediaItem copy;
  final int versionIndex;

  MediaVersion? get version {
    final versions = copy.mediaVersions;
    if (versions == null || versionIndex < 0 || versionIndex >= versions.length) return null;
    return versions[versionIndex];
  }

  /// See [copySourceKey].
  String get key => copySourceKey(copy, version);

  /// The version's height, else the copy's tallest, else null.
  int? get height => version?.resolutionHeight ?? _tallest(copy);

  int get bitrate => version?.bitrate ?? bestCopyBitrate(copy);

  @override
  bool operator ==(Object other) => other is CopySource && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'CopySource($key)';
}

/// Identity of one file: the server, the item's id on it (a Plex rating key)
/// and the version's id, e.g. `server|1234|5678`. Holds no token, address or
/// name. A copy with no known version ends in `|`, see [copyKeyPrefix].
String copySourceKey(MediaItem copy, MediaVersion? version) => '${copyKeyPrefix(copy)}${version?.id ?? ''}';

/// The part of [copySourceKey] every version of [copy] shares.
String copyKeyPrefix(MediaItem copy) => '${copy.serverId ?? ''}|${copy.id}|';

int? _tallest(MediaItem copy) {
  int? best;
  for (final version in copy.mediaVersions ?? const <MediaVersion>[]) {
    final height = version.resolutionHeight;
    if (height != null && (best == null || height > best)) best = height;
  }
  return best;
}

/// Every file of [copies], one [CopySource] per version, in the order given.
/// A copy listed twice (by [MediaItem.globalKey]) keeps its first entry, so a
/// caller puts the copy whose versions it checked first.
List<CopySource> expandCopySources(Iterable<MediaItem> copies) {
  final seen = <String>{};
  final sources = <CopySource>[];
  for (final copy in copies) {
    if (!seen.add(copy.globalKey)) continue;
    final count = copy.mediaVersions?.length ?? 0;
    if (count == 0) {
      sources.add(CopySource(copy, 0));
    } else {
      for (var i = 0; i < count; i++) {
        sources.add(CopySource(copy, i));
      }
    }
  }
  return sources;
}

/// Whether [source] was already tried: its own key, or, for a copy whose
/// versions are unknown, any version of it.
bool copySourceWasTried(CopySource source, Set<String> tried) {
  if (tried.contains(source.key)) return true;
  if (source.version != null) return tried.contains(copySourceKey(source.copy, null));
  final prefix = copyKeyPrefix(source.copy);
  return tried.any((key) => key.startsWith(prefix));
}

/// The files to try after an open failed, best first.
///
/// [referenceHeight] is the height the viewer asked for. Order:
/// 1. the same height, on a server that has not failed yet before one that
///    has, then the highest bitrate;
/// 2. lower heights, the tallest first;
/// 3. the rest (taller, or no height reported).
///
/// Within each, a server that already failed in this run ([failedServerIds])
/// comes after a fresh one, then the highest bitrate, then
/// [compareLibraryCopies]. Files in [tried] are dropped, as are versions the
/// server's file check marked unplayable. [isRemembered] (a file that failed
/// recently) sorts after everything else instead of being dropped: it may
/// work again, and it is better than nothing.
List<CopySource> orderCopyFallbacks({
  required Iterable<MediaItem> copies,
  required int? referenceHeight,
  Set<String> tried = const {},
  Set<String> failedServerIds = const {},
  bool Function(CopySource source)? isRemembered,
}) {
  final candidates = [
    for (final source in expandCopySources(copies))
      if (!copySourceWasTried(source, tried) && (source.version?.isPlayable ?? true)) source,
  ];
  int tier(CopySource s) {
    final height = s.height;
    if (referenceHeight == null) return 0;
    if (height == null) return 2;
    if (height == referenceHeight) return 0;
    return height < referenceHeight ? 1 : 2;
  }

  final remembered = {for (final s in candidates) s.key: isRemembered?.call(s) ?? false};
  candidates.sort((a, b) {
    final byRemembered = (remembered[a.key]! ? 1 : 0).compareTo(remembered[b.key]! ? 1 : 0);
    if (byRemembered != 0) return byRemembered;
    final byTier = tier(a).compareTo(tier(b));
    if (byTier != 0) return byTier;
    if (tier(a) != 0) {
      final byHeight = (b.height ?? 0).compareTo(a.height ?? 0);
      if (byHeight != 0) return byHeight;
    }
    final byFreshServer = (failedServerIds.contains(a.copy.serverId) ? 1 : 0).compareTo(
      failedServerIds.contains(b.copy.serverId) ? 1 : 0,
    );
    if (byFreshServer != 0) return byFreshServer;
    final byBitrate = b.bitrate.compareTo(a.bitrate);
    if (byBitrate != 0) return byBitrate;
    final byCopy = compareLibraryCopies(a.copy, b.copy);
    if (byCopy != 0) return byCopy;
    return a.versionIndex.compareTo(b.versionIndex);
  });
  return candidates;
}

/// Short quality of [source] for a notice or a log line: "4K", "1080p", or
/// null when the backend reported no resolution.
String? copySourceQualityLabel(CopySource source) {
  final version = source.version;
  final height = source.height;
  if (height == null) return null;
  if (height >= 2160) return '4K';
  if (version?.videoResolution?.toLowerCase() == 'sd') return 'SD';
  return '${height}p';
}

/// The `[CopyFallback]` log line for one attempt. Servers are numbered in the
/// order the run met them ([serverIndex]); no name, address, URL or token.
String copyFallbackLogLine({
  required CopyFallbackReason reason,
  required int attempt,
  required CopySource from,
  required CopySource to,
  required int Function(String? serverId) serverIndex,
}) {
  String describe(CopySource s) => '${copySourceQualityLabel(s) ?? '?'}@s${serverIndex(s.copy.serverId)}';
  final sameItem = from.copy.globalKey == to.copy.globalKey;
  return '[CopyFallback] attempt $attempt/$maxCopyFallbackAttempts reason=${reason.name} '
      'from=${describe(from)} to=${describe(to)}${sameItem ? ' (same item, other version)' : ''}';
}
