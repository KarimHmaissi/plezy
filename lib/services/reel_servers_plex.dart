import 'dart:async';

import '../media/ids.dart';
import 'multi_server_manager.dart';
import 'plex_client.dart';
import 'reel/clip_filter.dart';
import 'reel/clip_resolver.dart';

/// The Reel's only door to the Plex servers: per-title extras and clip URLs.
/// Lives outside `lib/services/reel/` so Reel code never imports the Plex
/// client (whose timeline and scrobble calls would report watch state).
class PlexReelServers implements ReelServers {
  PlexReelServers(this._servers);

  final MultiServerManager _servers;

  PlexClient? _client(String serverId) {
    final c = _servers.getClient(ServerId(serverId));
    return c is PlexClient ? c : null;
  }

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    final c = _client(serverId);
    if (c == null) return const [];
    return c.fetchExtraClips(ratingKey, timeout: timeout).timeout(timeout + const Duration(seconds: 1));
  }

  @override
  String? clipUrl(String serverId, String partKey) => _client(serverId)?.clipUrl(partKey);
}
