import 'dart:convert';
import 'dart:io';

import 'dialogue_chunks.dart';
import 'media_source.dart';
import 'subtitles.dart';

/// Per-leaf outcome, kept in `status.json` so a job resumes where it left
/// off and never redoes finished work.
enum LeafStatus { done, noSubtitles, failed }

class ExportSummary {
  ExportSummary();
  int done = 0, skipped = 0, noSubtitles = 0, failed = 0, sidecar = 0, embedded = 0, chunks = 0, busy = 0;

  /// The run stopped early because the server kept saying it was busy.
  bool stopped = false;

  Map<String, int> toJson() => {
    'done': done,
    'skipped': skipped,
    'noSubtitles': noSubtitles,
    'failed': failed,
    'sidecar': sidecar,
    'embedded': embedded,
    'chunks': chunks,
    'busy': busy,
    'stopped': stopped ? 1 : 0,
  };
}

/// Exports dialogue for titles into [outDir]: per leaf `<id>.srt` and
/// `<id>.chunks.json`, plus `manifest.jsonl` (one line per finished leaf)
/// and `status.json`. Resumable and idempotent; waits while [shouldPause]
/// says so (the host passes "something is playing") and leaves [gap]
/// between leaves so a big batch stays gentle on the server.
class DialogueExportJob {
  DialogueExportJob({
    required this.source,
    required this.outDir,
    this.allowEmbedded = false,
    this.ffmpeg = 'ffmpeg',
    this.gap = const Duration(milliseconds: 250),
    this.shouldPause,
    this.maxBusy = 3,
    this.busyBackoff = const Duration(seconds: 5),
    Future<void> Function(Duration)? sleep,
    SubtitleReader? reader,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _reader = reader ?? SubtitleReader(source, allowEmbedded: allowEmbedded, ffmpeg: ffmpeg);

  final MediaSource source;
  final Directory outDir;
  final bool allowEmbedded;
  final String ffmpeg;
  final Duration gap;
  final bool Function()? shouldPause;

  /// Busy answers (429/5xx) tolerated in a run, each followed by an
  /// exponentially longer wait ([busyBackoff], doubled each time).
  final int maxBusy;
  final Duration busyBackoff;
  final Future<void> Function(Duration) _sleep;
  final SubtitleReader _reader;

  File get _statusFile => File('${outDir.path}/status.json');
  File get _manifestFile => File('${outDir.path}/manifest.jsonl');

  Future<Map<String, Map<String, Object?>>> _readStatus() async {
    if (!await _statusFile.exists()) return {};
    final j = jsonDecode(await _statusFile.readAsString()) as Map<String, Object?>;
    return {for (final e in j.entries) e.key: (e.value as Map).cast<String, Object?>()};
  }

  /// Export every leaf under [ids]. [retry] also redoes leaves that had no
  /// subtitles or failed before.
  Future<ExportSummary> run(List<String> ids, {bool retry = false}) async {
    await outDir.create(recursive: true);
    final status = await _readStatus();
    final summary = ExportSummary();
    var first = true;

    Future<void> save() => _statusFile.writeAsString(jsonEncode(status));

    for (final id in ids) {
      for (final leaf in await source.leaves(id)) {
        final previous = status[leaf.id]?['status'];
        if (previous == LeafStatus.done.name || (!retry && previous != null)) {
          summary.skipped++;
          continue;
        }
        while (shouldPause?.call() ?? false) {
          await _sleep(const Duration(seconds: 30));
        }
        if (!first) await _sleep(gap);
        first = false;

        try {
          Dialogue? dialogue;
          while (true) {
            try {
              dialogue = await _reader.read(leaf.id);
              break;
            } on ServerBusyException {
              summary.busy++;
              if (summary.busy >= maxBusy) {
                summary.stopped = true;
                await save();
                await _writeManifest(status);
                return summary;
              }
              await _sleep(busyBackoff * (1 << (summary.busy - 1)));
            }
          }
          if (dialogue == null) {
            status[leaf.id] = {'status': LeafStatus.noSubtitles.name};
            summary.noSubtitles++;
          } else {
            final chunks = chunkDialogue(parseSrt(dialogue.srt));
            await File('${outDir.path}/${leaf.id}.srt').writeAsString(dialogue.srt);
            await File(
              '${outDir.path}/${leaf.id}.chunks.json',
            ).writeAsString(jsonEncode([for (final c in chunks) c.toJson()]));
            status[leaf.id] = {
              'status': LeafStatus.done.name,
              'source': dialogue.source.name,
              'chunks': chunks.length,
              'leaf': leaf.toJson(),
            };
            summary.done++;
            summary.chunks += chunks.length;
            dialogue.source == DialogueSource.sidecar ? summary.sidecar++ : summary.embedded++;
          }
        } catch (e) {
          // The error type only: messages can carry URLs with credentials.
          status[leaf.id] = {'status': LeafStatus.failed.name, 'error': e.runtimeType.toString()};
          summary.failed++;
        }
        await save();
      }
    }
    await _writeManifest(status);
    return summary;
  }

  Future<void> _writeManifest(Map<String, Map<String, Object?>> status) async {
    final lines = [
      for (final e in status.entries)
        if (e.value['status'] == LeafStatus.done.name)
          jsonEncode({...(e.value['leaf'] as Map).cast<String, Object?>(), 'source': e.value['source']}),
    ];
    await _manifestFile.writeAsString(lines.isEmpty ? '' : '${lines.join('\n')}\n');
  }
}
