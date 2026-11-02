import 'dart:convert';
import 'dart:io';

import '../../utils/app_logger.dart';
import '../plex_client.dart';

/// Where a title's subtitle text came from.
enum SubtitleSource { sidecar, embedded }

/// One movie or episode's dialogue as SRT, with what it is.
class FetchedSubtitles {
  const FetchedSubtitles({required this.item, required this.srt, required this.source});

  /// The item's `/library/metadata` entry (title, index, parentIndex,
  /// grandparentTitle, duration, ...).
  final Map<String, dynamic> item;
  final String srt;
  final SubtitleSource source;
}

/// Fork: reads a title's English dialogue from a Plex server without
/// playing it. A sidecar file (`/library/streams/{id}.srt`) is a plain
/// download; an embedded text track is pulled out of the media part by
/// ffmpeg over the LAN (reads much of the file, so batch it when idle).
/// Image subtitles (PGS, VobSub) have no text and are skipped.
///
/// The future indexer's way in; today only the debug lab export uses it.
class SubtitleFetcher {
  SubtitleFetcher(this.client, {this.ffmpeg = 'ffmpeg', this.allowEmbedded = false});

  final PlexClient client;
  final String ffmpeg;

  /// Embedded tracks cost a large read of the media file; off unless asked.
  final bool allowEmbedded;

  static const _textCodecs = {'srt', 'subrip', 'mov_text', 'ass', 'ssa', 'webvtt', 'vtt', 'text'};

  /// Movies and episodes under [ratingKey]: itself for a movie or episode,
  /// every episode for a show or season.
  Future<List<Map<String, dynamic>>> leaves(String ratingKey) async {
    final item = await _metadata(ratingKey);
    if (item == null) return const [];
    final type = item['type'];
    if (type == 'movie' || type == 'episode') return [item];
    final json = await client.getJson('/library/metadata/$ratingKey/allLeaves');
    final list = (json?['MediaContainer'] as Map?)?['Metadata'] as List? ?? const [];
    return [for (final e in list.whereType<Map>()) e.cast<String, dynamic>()];
  }

  Future<Map<String, dynamic>?> _metadata(String ratingKey) async {
    final json = await client.getJson('/library/metadata/$ratingKey');
    final list = (json?['MediaContainer'] as Map?)?['Metadata'] as List?;
    return (list?.firstOrNull as Map?)?.cast<String, dynamic>();
  }

  /// The best English text track of [ratingKey], or null when it has none
  /// this fetcher can read.
  Future<FetchedSubtitles?> fetch(String ratingKey) async {
    final item = await _metadata(ratingKey);
    if (item == null) return null;
    final candidates = <({Map<String, dynamic> stream, String partKey})>[];
    for (final media in (item['Media'] as List? ?? const []).whereType<Map>()) {
      for (final part in (media['Part'] as List? ?? const []).whereType<Map>()) {
        for (final stream in (part['Stream'] as List? ?? const []).whereType<Map>()) {
          if (stream['streamType'] != 3) continue;
          final lang = '${stream['languageCode'] ?? stream['languageTag'] ?? ''}';
          if (!lang.startsWith('en')) continue;
          if (!_textCodecs.contains('${stream['codec']}'.toLowerCase())) continue;
          candidates.add((stream: stream.cast<String, dynamic>(), partKey: '${part['key']}'));
        }
      }
    }
    // Full dialogue first: sidecar before embedded, plain before SDH, never
    // forced-only (signs and foreign lines).
    int rank(Map<String, dynamic> s) {
      final sdh =
          '${s['title'] ?? s['displayTitle'] ?? ''}'.toLowerCase().contains('sdh') || s['hearingImpaired'] == true;
      return (s['key'] != null ? 0 : 10) + (sdh ? 1 : 0) + (s['forced'] == true ? 100 : 0);
    }

    candidates.sort((a, b) => rank(a.stream).compareTo(rank(b.stream)));
    for (final c in candidates) {
      if (c.stream['forced'] == true) continue;
      final key = c.stream['key'];
      if (key is String && key.isNotEmpty) {
        final srt = await client.getText('$key.srt', query: {'encoding': 'utf-8'});
        if (srt.trim().isNotEmpty) return FetchedSubtitles(item: item, srt: srt, source: SubtitleSource.sidecar);
      } else if (allowEmbedded) {
        final srt = await _extract(c.partKey, c.stream['index']);
        if (srt != null) return FetchedSubtitles(item: item, srt: srt, source: SubtitleSource.embedded);
      }
    }
    return null;
  }

  Future<String?> _extract(String partKey, Object? streamIndex) async {
    final url = client.partFileUrl(partKey);
    if (url == null || streamIndex is! int) return null;
    // Only the subtitle stream is decoded; the rest of the file is read past.
    final result = await Process.run(ffmpeg, [
      '-v', 'error', '-nostdin', //
      '-i', url,
      '-map', '0:$streamIndex',
      '-f', 'srt', '-',
    ], stdoutEncoding: utf8);
    if (result.exitCode != 0) {
      // ffmpeg's error text can echo the URL (and its token): don't log it.
      appLogger.w('Subtitle fetch: ffmpeg failed (exit ${result.exitCode})');
      return null;
    }
    final out = result.stdout as String;
    return out.trim().isEmpty ? null : out;
  }
}
