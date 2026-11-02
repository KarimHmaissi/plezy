import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:plezy_brain/plezy_brain.dart';

import '../plex_client.dart';

/// Fork: Plezy's side of the brain package. Implements [MediaSource] on an
/// existing [PlexClient]'s connection, so the server's credentials stay
/// inside the app; the brain never sees Plezy's internals.
class PlexBrainSource implements MediaSource {
  PlexBrainSource(this._client, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final PlexClient _client;
  final http.Client _http;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${_client.config.baseUrl}$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    'X-Plex-Client-Identifier': _client.config.clientIdentifier,
    'X-Plex-Token': ?_client.config.token,
  };

  Future<List<Map<String, dynamic>>> _metadata(String path) async {
    final res = await _http.get(_uri(path), headers: _headers);
    if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}');
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final list = (body['MediaContainer'] as Map?)?['Metadata'] as List? ?? const [];
    return [for (final m in list.whereType<Map>()) m.cast<String, dynamic>()];
  }

  MediaLeaf _leaf(Map<String, dynamic> m) => MediaLeaf(
    id: '${m['ratingKey']}',
    type: '${m['type']}',
    show: m['grandparentTitle'] as String?,
    season: m['parentIndex'] as int?,
    episode: m['index'] as int?,
    title: m['title'] as String?,
    year: m['year'] as int?,
    durationMs: m['duration'] as int?,
  );

  @override
  Future<List<MediaLeaf>> leaves(String id) async {
    final item = (await _metadata('/library/metadata/$id')).firstOrNull;
    if (item == null) return const [];
    if (item['type'] == 'movie' || item['type'] == 'episode') return [_leaf(item)];
    return [for (final m in await _metadata('/library/metadata/$id/allLeaves')) _leaf(m)];
  }

  @override
  Future<List<SubtitleStream>> subtitleStreams(String id) async {
    final item = (await _metadata('/library/metadata/$id')).firstOrNull;
    return [
      for (final media in (item?['Media'] as List? ?? const []).whereType<Map>())
        for (final part in (media['Part'] as List? ?? const []).whereType<Map>())
          for (final s in (part['Stream'] as List? ?? const []).whereType<Map>())
            if (s['streamType'] == 3)
              SubtitleStream(
                language: '${s['languageCode'] ?? s['languageTag'] ?? ''}',
                codec: '${s['codec'] ?? ''}',
                sidecarKey: s['key'] as String?,
                partKey: part['key'] as String?,
                index: s['index'] as int?,
                forced: s['forced'] == true,
                hearingImpaired:
                    s['hearingImpaired'] == true ||
                    '${s['title'] ?? s['displayTitle'] ?? ''}'.toLowerCase().contains('sdh'),
              ),
    ];
  }

  @override
  Future<String> fetchSidecar(SubtitleStream stream) async {
    final res = await _http.get(_uri('${stream.sidecarKey}.srt', {'encoding': 'utf-8'}), headers: _headers);
    if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}');
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  @override
  String? partUrl(String partKey) {
    final token = _client.config.token;
    return token == null ? null : _uri(partKey, {'X-Plex-Token': token}).toString();
  }
}
