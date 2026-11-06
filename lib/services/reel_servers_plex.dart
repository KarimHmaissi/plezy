import 'dart:async';

import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import 'multi_server_manager.dart';
import 'plex_api_cache.dart';
import 'plex_client.dart';
import 'plex_mappers.dart';
import 'reel/clip_filter.dart';
import 'reel/clip_resolver.dart';
import 'reel/reel_metadata.dart';

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

/// The Reel's metadata seam on the Plex servers (plan V2-03): the app's
/// cached row, else one lean read the Reel keeps in its own cache.
class PlexReelMetadata implements ReelMetadataSource {
  PlexReelMetadata(this._servers, {PlexApiCache Function()? cache}) : _cache = cache ?? (() => PlexApiCache.instance);

  final MultiServerManager _servers;
  final PlexApiCache Function() _cache;

  PlexClient? _plex(String serverId) {
    final c = _servers.getClient(ServerId(serverId));
    return c is PlexClient ? c : null;
  }

  /// Whether [serverId] is a Plex server (other backends keep their own
  /// item read).
  bool serves(String serverId) => _plex(serverId) != null;

  @override
  String? scope(String serverId) => _plex(serverId)?.cacheServerId;

  @override
  Future<MediaItem?> cached(String serverId, String ratingKey, {Duration? maxAge}) async {
    final scope = this.scope(serverId);
    if (scope == null) return null;
    final cache = _cache();
    return maxAge == null
        ? cache.getMetadata(ServerId(scope), ratingKey)
        : cache.getMetadataIfFresh(ServerId(scope), ratingKey, maxAge: maxAge);
  }

  @override
  Future<Map<String, dynamic>?> lean(String serverId, String ratingKey) async {
    final c = _plex(serverId);
    if (c == null || !_servers.isServerOnline(ServerId(serverId))) throw ReelServerUnavailable(serverId);
    return c.fetchReelMetadataJson(ratingKey).timeout(const Duration(seconds: 16));
  }

  @override
  MediaItem parse(String serverId, Map<String, dynamic> json) =>
      PlexMappers.mediaItemFromCacheJson(json, serverId: ServerId(serverId));
}
