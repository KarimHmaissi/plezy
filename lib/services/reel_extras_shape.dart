import '../media/media_file_info.dart';
import 'plex_playback_mapper.dart';
import 'reel/clip_filter.dart';
import 'reel/clip_resolver.dart';

/// Fork, The Reel measure day (plan V2-20 step 1, decision D10): the shape
/// of the servers' extras. How many `Media` each extra has, and their
/// resolution, bitrate, codecs and channels, so step 2 (picking a variant
/// per device) is built only if the servers really offer a choice.
///
/// Counts only. A title, rating key, part URL, file path or server name
/// never reaches a line: server words (a codec, a profile) are kept only
/// when they look like one, and anything else counts as `other`.
class ExtrasShape {
  /// Copies whose extras were read.
  int copies = 0;

  /// Of [copies], the 4K library's.
  int copies4k = 0;

  /// Copies that listed at least one extra.
  int copiesWithExtras = 0;

  /// Reads that failed (a timeout, a 401, a 5xx).
  int failed = 0;

  /// Copies skipped: their server isn't a connected Plex server.
  int skipped = 0;

  int extras = 0;

  /// Of [extras], the ones the clip ladder would treat as a trailer.
  int trailers = 0;

  /// Extras with more than one `Media`, and of those, the ones whose
  /// `Media` differ in resolution, bitrate, video codec or audio codec:
  /// the variety step 2 waits on.
  int multiMedia = 0;
  int differResolution = 0;
  int differBitrate = 0;
  int differVideoCodec = 0;
  int differAudioCodec = 0;

  /// `Media` per extra (`0`, `1`, `2`, `3+`).
  final Map<String, int> mediaPerExtra = {};

  /// `Part` per `Media` (`0`, `1`, `2+`).
  final Map<String, int> partsPerMedia = {};

  // Per Media.
  final Map<String, int> resolution = {};
  final Map<String, int> bitrate = {};
  final Map<String, int> videoCodec = {};
  final Map<String, int> videoProfile = {};
  final Map<String, int> audioCodec = {};
  final Map<String, int> channels = {};
  final Map<String, int> container = {};

  // Per Part: where it is served from, and the `bitrate=` its key asks for.
  final Map<String, int> partSource = {};
  final Map<String, int> partBitrate = {};

  /// One copy's extras, as `/library/metadata/{id}/extras` lists them.
  void addCopy(List<Object?> rows, {bool is4k = false}) {
    copies++;
    if (is4k) copies4k++;
    var listed = 0;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is! Map<String, dynamic>) continue;
      listed++;
      _addExtra(row, i);
    }
    if (listed > 0) copiesWithExtras++;
  }

  void _addExtra(Map<String, dynamic> row, int index) {
    extras++;
    // The ladder's own reading of the row; a row with no playable part has
    // no clip and counts as not a trailer.
    if (PlexExtraClip.fromJson(row, index)?.isTrailer ?? false) trailers++;
    // The app's own reader for every Media and Part (the file-info sheet's).
    final versions = parsePlexFileInfoFromJson(row)?.versions ?? const <MediaFileVersion>[];
    _bump(mediaPerExtra, switch (versions.length) {
      0 => '0',
      1 => '1',
      2 => '2',
      _ => '3+',
    });
    for (final v in versions) {
      _bump(partsPerMedia, switch (v.parts.length) {
        0 => '0',
        1 => '1',
        _ => '2+',
      });
      _bump(resolution, word(v.videoResolutionLabel));
      _bump(bitrate, bitrateBand(v.bitrateKbps));
      _bump(videoCodec, word(v.videoCodec));
      _bump(videoProfile, word(v.videoProfile));
      _bump(audioCodec, word(v.audioCodec));
      _bump(channels, v.audioChannels == null ? '?' : (v.audioChannels! >= 9 ? '9+' : '${v.audioChannels}'));
      _bump(container, word(v.container));
      for (final p in v.parts) {
        _bump(partSource, partSourceOf(p.streamKey));
        _bump(partBitrate, partBitrateOf(p.streamKey));
      }
    }
    if (versions.length > 1) {
      multiMedia++;
      bool differ(Object? Function(MediaFileVersion v) f) => versions.map(f).toSet().length > 1;
      if (differ((v) => v.videoResolutionLabel)) differResolution++;
      if (differ((v) => v.bitrateKbps)) differBitrate++;
      if (differ((v) => v.videoCodec)) differVideoCodec++;
      if (differ((v) => v.audioCodec)) differAudioCodec++;
    }
  }

  static void _bump(Map<String, int> m, String key) => m[key] = (m[key] ?? 0) + 1;

  static final RegExp _word = RegExp(r'^[a-z0-9][a-z0-9 ._+-]{0,15}$');

  /// A server word (a codec, a profile, a resolution label) when it looks
  /// like one, `?` when missing, and `other` for anything else, so free
  /// text can never reach the log.
  static String word(String? value) {
    final v = value?.trim().toLowerCase();
    if (v == null || v.isEmpty) return '?';
    return _word.hasMatch(v) ? v : 'other';
  }

  /// A bitrate in kbps, as a band.
  static String bitrateBand(int? kbps) => switch (kbps) {
    null || <= 0 => '?',
    < 1500 => '<1.5M',
    < 5000 => '1.5-5M',
    < 10000 => '5-10M',
    < 20000 => '10-20M',
    _ => '20M+',
  };

  /// Where a part is served from: Plex's trailer service (`iva`), a file in
  /// the library (`library`), elsewhere (`other`) or no key (`none`).
  static String partSourceOf(String? key) {
    if (key == null || key.isEmpty) return 'none';
    final path = Uri.tryParse(key)?.path ?? '';
    if (path.startsWith('/services/iva/')) return 'iva';
    if (path.startsWith('/library/parts/')) return 'library';
    return 'other';
  }

  /// The `bitrate=` a part key asks for, as a band of the number alone, or
  /// `none` when it asks for none.
  static String partBitrateOf(String? key) {
    final raw = key == null ? null : Uri.tryParse(key)?.queryParameters['bitrate'];
    if (raw == null) return 'none';
    final n = int.tryParse(raw);
    return n == null ? 'other' : bitrateBand(n);
  }

  static String _counts(Map<String, int> m) {
    final e = m.entries.toList()..sort((a, b) => b.value != a.value ? b.value - a.value : a.key.compareTo(b.key));
    return '{${e.map((x) => '${x.key}: ${x.value}').join(', ')}}';
  }

  /// The log lines, each starting `[ReelProbe] extras-shape`.
  List<String> lines() => [
    '[ReelProbe] extras-shape: $copies copies read ($copies4k 4K), $copiesWithExtras with extras, '
        '$failed failed, $skipped skipped (not a connected Plex server); $extras extras, $trailers trailers',
    '[ReelProbe] extras-shape media per extra ${_counts(mediaPerExtra)}, parts per media ${_counts(partsPerMedia)}',
    '[ReelProbe] extras-shape resolution ${_counts(resolution)}, bitrate ${_counts(bitrate)}',
    '[ReelProbe] extras-shape video ${_counts(videoCodec)}, profile ${_counts(videoProfile)}, '
        'container ${_counts(container)}',
    '[ReelProbe] extras-shape audio ${_counts(audioCodec)}, channels ${_counts(channels)}',
    '[ReelProbe] extras-shape parts from ${_counts(partSource)}, key bitrate ${_counts(partBitrate)}',
    '[ReelProbe] extras-shape variety: $multiMedia extras with more than one Media; of those, '
        'resolution differs $differResolution, bitrate $differBitrate, video codec $differVideoCodec, '
        'audio codec $differAudioCodec',
  ];
}

/// Reads one copy's extras rows. Throws when the read failed; returns null
/// when the copy's server isn't a connected Plex server.
typedef ExtrasRowsRead = Future<List<Object?>?> Function(ReelCopy copy);

/// The probe's walk: every copy of up to [maxTitles] titles, one request at
/// a time with [gap] after each one (a failed read too, so a server that
/// refuses every read is never hammered), [maxReads] reads at most.
/// [pause] waits out the gap (tests pass a recorder).
Future<ExtrasShape> probeExtrasShape(
  List<ReelTitle> titles,
  ExtrasRowsRead read, {
  int maxTitles = 30,
  int maxReads = 60,
  Duration gap = const Duration(milliseconds: 150),
  Future<void> Function(Duration gap)? pause,
}) async {
  final wait = pause ?? (Duration d) => Future<void>.delayed(d);
  final shape = ExtrasShape();
  var reads = 0;
  for (final t in titles.take(maxTitles)) {
    for (final c in t.copies) {
      if (reads >= maxReads) return shape;
      List<Object?>? rows;
      try {
        rows = await read(c);
      } catch (_) {
        reads++;
        shape.failed++;
        if (gap > Duration.zero) await wait(gap);
        continue;
      }
      if (rows == null) {
        shape.skipped++;
        continue;
      }
      reads++;
      shape.addCopy(rows, is4k: c.is4k);
      if (gap > Duration.zero) await wait(gap);
    }
  }
  return shape;
}
