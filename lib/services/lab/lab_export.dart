import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:plezy_brain/plezy_brain.dart';

import '../../media/ids.dart';
import '../../providers/multi_server_provider.dart';
import '../plex_client.dart';
import 'plex_brain_source.dart';

/// Debug builds on a Mac only: never registered in release.
final bool labExportEnabled = !kReleaseMode && Platform.isMacOS;

/// Fork, debug only: `ext.plezy.labSubtitles` runs the brain's dialogue
/// export for the given titles (movies, episodes, whole shows or seasons)
/// into `~/Library/Application Support/PlezyLab/raw`, outside the repo,
/// through the app's own server connection.
///
/// Params: `server` (machine id), `keys` (comma-separated rating keys),
/// `embedded` ("true" to also extract embedded tracks with ffmpeg), `retry`.
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
        return developer.ServiceExtensionResponse.result(jsonEncode(await _run(params)));
      } catch (e) {
        // The type only: messages can carry URLs with credentials.
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
    final home = Platform.environment['HOME'];
    final job = DialogueExportJob(
      source: PlexBrainSource(client),
      outDir: Directory('$home/Library/Application Support/PlezyLab/raw'),
      allowEmbedded: params['embedded'] == 'true',
      ffmpeg: File('/opt/homebrew/bin/ffmpeg').existsSync() ? '/opt/homebrew/bin/ffmpeg' : 'ffmpeg',
    );
    final keys = [
      for (final k in (params['keys'] ?? '').split(','))
        if (k.trim().isNotEmpty) k.trim(),
    ];
    return (await job.run(keys, retry: params['retry'] == 'true')).toJson();
  }
}
