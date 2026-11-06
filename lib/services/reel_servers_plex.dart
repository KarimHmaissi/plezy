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

  /// A connected Plex client for [serverId]: online, as deep links judge it.
  PlexClient? _client(String serverId) {
    final id = ServerId(serverId);
    final c = _servers.getClient(id);
    return c is PlexClient && _servers.isServerOnline(id) ? c : null;
  }

  /// Whether [serverId] can answer now (what the resume wait waits for).
  bool connected(String serverId) => _client(serverId) != null;

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    final c = _client(serverId);
    if (c == null) throw ReelServerUnavailable(serverId);
    return c.fetchExtraClips(ratingKey, timeout: timeout).timeout(timeout + const Duration(seconds: 1));
  }

  @override
  String? clipUrl(String serverId, String partKey) => _client(serverId)?.clipUrl(partKey);
}
