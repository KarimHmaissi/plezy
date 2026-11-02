import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../media/ids.dart';
import '../../providers/multi_server_provider.dart';
import '../plex_client.dart';
import 'subtitle_fetcher.dart';

/// Debug builds on a Mac only: never registered in release.
final bool labExportEnabled = !kReleaseMode && Platform.isMacOS;

/// Fork, debug only: `ext.plezy.labSubtitles` writes the English dialogue of
/// the given titles (movies, episodes, or whole shows/seasons) to
/// `~/Library/Application Support/PlezyLab/raw`, outside the repo, using the
/// app's own server connection. For indexing experiments.
///
/// Params: `server` (machine id), `keys` (comma-separated rating keys),
/// `embedded` ("true" to also extract embedded tracks with ffmpeg).
/// Returns counts only.
abstract final class LabExport {
  static const extensionName = 'ext.plezy.labSubtitles';
  static MultiServerProvider? _servers;
  static bool _registered = false;

  static void attach(MultiServerProvider servers) {
    if (!labExportEnabled) return;
    _servers = servers;
    if (_registered) return;
    _registered = true;
    developer.registerExtension(extensionName, (_, params) async {
      try {
        final result = await _run(params);
        return developer.ServiceExtensionResponse.result(jsonEncode(result));
      } catch (e) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          e.runtimeType.toString(),
        );
      }
    });
  }

  static Future<Map<String, Object?>> _run(Map<String, String> params) async {
    final client = _servers?.getClientForServer(ServerId(params['server'] ?? ''));
    if (client is! PlexClient) return {'error': 'noPlexServer'};
    final keys = (params['keys'] ?? '').split(',').where((k) => k.trim().isNotEmpty).toList();
    final fetcher = SubtitleFetcher(
      client,
      ffmpeg: File('/opt/homebrew/bin/ffmpeg').existsSync() ? '/opt/homebrew/bin/ffmpeg' : 'ffmpeg',
      allowEmbedded: params['embedded'] == 'true',
    );
    final home = Platform.environment['HOME'];
    final dir = Directory('$home/Library/Application Support/PlezyLab/raw');
    await dir.create(recursive: true);
    final manifest = File('${dir.path}/manifest.jsonl').openWrite(mode: FileMode.append);
    var written = 0, missing = 0, sidecar = 0, embedded = 0;
    try {
      for (final key in keys) {
        for (final leaf in await fetcher.leaves(key.trim())) {
          final rk = '${leaf['ratingKey']}';
          final got = await fetcher.fetch(rk);
          if (got == null) {
            missing++;
            continue;
          }
          await File('${dir.path}/$rk.srt').writeAsString(got.srt);
          final m = got.item;
          manifest.writeln(
            jsonEncode({
              'ratingKey': rk,
              'type': m['type'],
              'show': m['grandparentTitle'],
              'season': m['parentIndex'],
              'episode': m['index'],
              'title': m['title'],
              'year': m['year'],
              'durationMs': m['duration'],
              'source': got.source.name,
            }),
          );
          written++;
          got.source == SubtitleSource.sidecar ? sidecar++ : embedded++;
        }
      }
    } finally {
      await manifest.close();
    }
    return {'written': written, 'missing': missing, 'sidecar': sidecar, 'embedded': embedded};
  }
}
