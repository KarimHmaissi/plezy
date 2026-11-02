import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'media_source.dart';

/// Where a leaf's dialogue came from.
enum DialogueSource { sidecar, embedded }

class Dialogue {
  const Dialogue(this.srt, this.source);
  final String srt;
  final DialogueSource source;
}

/// Picks and reads a leaf's English dialogue: a separate file when there is
/// one (a plain download), otherwise an embedded text track pulled out by
/// ffmpeg (which reads much of the media file, so only when [allowEmbedded]).
/// Forced (signs only) and image tracks (PGS, VobSub) are never used.
class SubtitleReader {
  SubtitleReader(this.source, {this.allowEmbedded = false, this.ffmpeg = 'ffmpeg', ProcessRunner? run})
    : _run = run ?? _processRun;

  final MediaSource source;
  final bool allowEmbedded;
  final String ffmpeg;
  final ProcessRunner _run;

  static const textCodecs = {'srt', 'subrip', 'mov_text', 'ass', 'ssa', 'webvtt', 'vtt', 'text'};

  /// Candidate tracks, best first: English text, sidecar before embedded,
  /// plain before SDH.
  static List<SubtitleStream> rank(List<SubtitleStream> streams) {
    final usable = [
      for (final s in streams)
        if (s.language.toLowerCase().startsWith('en') && !s.forced && textCodecs.contains(s.codec.toLowerCase())) s,
    ];
    int score(SubtitleStream s) => (s.isSidecar ? 0 : 10) + (s.hearingImpaired ? 1 : 0);
    return usable..sort((a, b) => score(a).compareTo(score(b)));
  }

  Future<Dialogue?> read(String leafId) async {
    for (final s in rank(await source.subtitleStreams(leafId))) {
      if (s.isSidecar) {
        final srt = await source.fetchSidecar(s);
        if (srt.trim().isNotEmpty) return Dialogue(srt, DialogueSource.sidecar);
      } else if (allowEmbedded && s.partKey != null && s.index != null) {
        final srt = await _extract(s.partKey!, s.index!);
        if (srt != null) return Dialogue(srt, DialogueSource.embedded);
      }
    }
    return null;
  }

  Future<String?> _extract(String partKey, int index) async {
    final url = source.partUrl(partKey);
    if (url == null) return null;
    // Only the subtitle stream is decoded. Errors are dropped, not logged:
    // ffmpeg can echo the URL, which carries credentials.
    final result = await _run(ffmpeg, ['-v', 'error', '-nostdin', '-i', url, '-map', '0:$index', '-f', 'srt', '-']);
    if (result.exitCode != 0) return null;
    final out = result.stdout;
    return out.trim().isEmpty ? null : out;
  }
}

typedef ProcessRunner = Future<({int exitCode, String stdout})> Function(String exe, List<String> args);

Future<({int exitCode, String stdout})> _processRun(String exe, List<String> args) async {
  final r = await Process.run(exe, args, stdoutEncoding: utf8);
  return (exitCode: r.exitCode, stdout: r.stdout as String);
}
