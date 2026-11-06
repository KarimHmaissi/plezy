import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../media/ids.dart';
import '../media/media_kind.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/multi_server_provider.dart';
import '../screens/reel/reel_screen.dart';
import '../utils/app_logger.dart';
import '../utils/external_ids.dart';
import 'ai/facts/index_title_facts_source.dart';
import 'catalog/plex_catalog_source.dart';
import 'library_index/library_index.dart';
import 'reel/clip_player.dart';
import 'reel/reel_decks.dart';
import 'reel/reel_library.dart';
import 'reel/reel_store.dart';
import 'reel_app.dart';
import 'tmdb/tmdb_key_store.dart';

/// Fork, The Reel measure day (spec §10): clip coverage over the first 50
/// shows of the For You pool, read only, one request at a time. Started by
/// `plezy://reel?probe=coverage` over adb; `probe=watchstate` reads the
/// shown card's watch state. Logs counts and response shapes
/// only: never a title, URL, token or key.
abstract final class ReelProbe {
  static bool _running = false;

  static Future<void> run(BuildContext context, {int shows = 50, int catalogue = 5}) async {
    if (_running) return;
    _running = true;
    try {
      final multi = context.read<MultiServerProvider>();
      final plex = context.read<CatalogSourcesProvider?>()?.connectedSources.whereType<PlexCatalogSource>().firstOrNull;
      final store = ReelStore.instance;
      final library = ReelLibrary(database: () => LibraryIndex.instance.database, facts: IndexTitleFactsSource.app());
      final resolver = ReelApp.resolverFor(multi.serverManager, store);

      final candidates = await forYouCandidates(library: library, store: store);
      final showEntries = [
        for (final c in candidates)
          if (c.entry.isShow == true) c.entry,
      ];
      final cards = (await library.cards(showEntries)).take(shows).toList();
      final fromPool = cards.length;
      // The pool is mostly films: fill the sample with random library shows.
      if (cards.length < shows) {
        final db = await LibraryIndex.instance.database;
        final rows = await db
            .customSelect("SELECT * FROM index_titles WHERE type = 'show' ORDER BY random() LIMIT 200")
            .get();
        final extra = await library.cards([
          for (final r in rows)
            DeckEntry(serverId: r.read<String>('server_id'), ratingKey: r.read<String>('rating_key'), isShow: true),
        ]);
        final have = {for (final c in cards) c.title.groupKey};
        for (final c in extra) {
          if (cards.length >= shows) break;
          if (have.add(c.title.groupKey)) cards.add(c);
        }
      }
      appLogger.i(
        '[ReelProbe] pool: ${candidates.length} candidates; ${cards.length} shows probed '
        '($fromPool from the pool, ${cards.length - fromPool} random library shows)',
      );

      var plexClip = 0, animeClip = 0, none = 0, anime = 0;
      final missing = <ReelCardData>[];
      final sw = Stopwatch()..start();
      for (final c in cards) {
        if (c.title.anime) anime++;
        final r = await resolver.resolve(c.title);
        switch (r?.source.origin) {
          case ClipOrigin.plexExtra:
            plexClip++;
          case ClipOrigin.animeTheme:
            animeClip++;
          case null:
            none++;
            missing.add(c);
        }
      }
      appLogger.i(
        '[ReelProbe] servers: IVA/extras trailer $plexClip, AnimeThemes OP $animeClip, '
        'none $none of ${cards.length} (anime-library $anime) in ${sw.elapsedMilliseconds} ms',
      );

      await _tmdb(cards);
      if (plex != null) await _catalogue(plex, missing.take(catalogue).toList());
    } catch (e, st) {
      appLogger.w('[ReelProbe] failed', error: e, stackTrace: st);
    } finally {
      _running = false;
    }
  }

  /// Before and after a clip plays: the shown title's and its trailer's
  /// watch state on the server (`plezy://reel?probe=watchstate`). Clips
  /// must never move any of it. Logs numbers and a short id hash only.
  static Future<void> watchState(BuildContext context) async {
    final c = ReelScreen.liveController;
    final slot = c?.current;
    final card = slot?.card;
    if (c == null || card == null) {
      appLogger.i('[ReelProbe] watchstate: the Reel is not showing a card');
      return;
    }
    final multi = context.read<MultiServerProvider>();
    final client = multi.getClientForServer(ServerId(card.best.serverId));
    if (client == null) return;
    String tag(String rk) => rk.hashCode.toUnsigned(20).toRadixString(36);
    try {
      final r = await client.fetchItemWithOnDeck(card.best.ratingKey);
      final t = r.item;
      appLogger.i(
        '[ReelProbe] watchstate title ${tag(card.best.ratingKey)}: viewOffset ${t?.viewOffsetMs}, '
        'lastViewedAt ${t?.lastViewedAt}, viewCount ${t?.viewCount}, '
        'onDeck ${r.onDeckEpisode == null ? 'none' : '${tag(r.onDeckEpisode!.id)} offset ${r.onDeckEpisode!.viewOffsetMs} '
                  'lastViewedAt ${r.onDeckEpisode!.lastViewedAt}'}',
      );
      final asset = slot?.clip?.assetId;
      if (asset != null && asset.startsWith('plex:')) {
        final extra = await client.fetchItem(asset.substring(5));
        appLogger.i(
          '[ReelProbe] watchstate trailer ${tag(asset)}: viewOffset ${extra?.viewOffsetMs}, '
          'lastViewedAt ${extra?.lastViewedAt}, viewCount ${extra?.viewCount}, phase ${c.clips.phase.value.name}',
        );
      } else {
        appLogger.i('[ReelProbe] watchstate clip: ${asset == null ? 'none' : 'AnimeThemes (not on the server)'}');
      }
    } catch (e) {
      appLogger.w('[ReelProbe] watchstate failed', error: e);
    }
  }

  /// TMDB `/3/tv/{id}/videos`: how many shows have a YouTube trailer or
  /// teaser (TMDB only ever lists YouTube/Vimeo links, never a stream).
  static Future<void> _tmdb(List<ReelCardData> cards) async {
    final key = await TmdbKeyStore.read();
    if (key == null || key.isEmpty) {
      appLogger.i('[ReelProbe] tmdb: no key set, skipped');
      return;
    }
    final kind = TmdbKeyStore.kindOf(key);
    final client = http.Client();
    var withId = 0, trailer = 0, opening = 0, failed = 0;
    var shapeLogged = false;
    try {
      for (final c in cards) {
        final id = int.tryParse(c.best.tmdb ?? '');
        if (id == null) continue;
        withId++;
        final base = Uri.parse('https://api.themoviedb.org/3/tv/$id/videos');
        final request = http.Request(
          'GET',
          kind == TmdbKeyKind.apiKey ? base.replace(queryParameters: {'api_key': key}) : base,
        );
        request.headers['Accept'] = 'application/json';
        if (kind == TmdbKeyKind.readAccessToken) request.headers['Authorization'] = 'Bearer $key';
        try {
          final response = await http.Response.fromStream(
            await client.send(request).timeout(const Duration(seconds: 15)),
          );
          if (response.statusCode != 200) {
            failed++;
            continue;
          }
          final body = jsonDecode(response.body) as Map;
          final results = (body['results'] as List? ?? const []).whereType<Map>().toList();
          if (!shapeLogged && results.isNotEmpty) {
            shapeLogged = true;
            appLogger.i(
              '[ReelProbe] tmdb shape: top ${body.keys.toList()}, result ${results.first.keys.toList()}, '
              'sites ${results.map((r) => r['site']).toSet()}, types ${results.map((r) => r['type']).toSet()}',
            );
          }
          bool has(Set<String> types) => results.any((r) => r['site'] == 'YouTube' && types.contains(r['type']));
          if (has({'Trailer', 'Teaser'})) trailer++;
          if (has({'Opening Credits'})) opening++;
        } catch (_) {
          failed++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      client.close();
    }
    appLogger.i(
      '[ReelProbe] tmdb: $withId of ${cards.length} have a TMDB id; YouTube trailer/teaser $trailer, '
      'opening credits $opening, failed $failed',
    );
  }

  /// plex.tv's catalogue (Discover) for shows the servers have no trailer
  /// for: does it list extras, and what are they?
  static Future<void> _catalogue(PlexCatalogSource plex, List<ReelCardData> cards) async {
    var matched = 0, withExtras = 0, playable = 0;
    for (final c in cards) {
      final ids = ExternalIds(
        imdb: c.best.imdb,
        tmdb: int.tryParse(c.best.tmdb ?? ''),
        tvdb: int.tryParse(c.best.tvdb ?? ''),
      );
      try {
        final meta = await plex.discover.match(ids, kind: MediaKind.show);
        final rk = meta?['ratingKey'];
        if (rk is! String) continue;
        matched++;
        final extras = await plex.discover.getExtras(rk);
        if (extras == null) {
          appLogger.i('[ReelProbe] catalogue: extras endpoint 404');
          continue;
        }
        if (extras.isEmpty) continue;
        withExtras++;
        final first = extras.first;
        final media = (first['Media'] as List?)?.whereType<Map>().firstOrNull;
        final part = (media?['Part'] as List?)?.whereType<Map>().firstOrNull;
        final partKey = part?['key'];
        final host = partKey is String ? (Uri.tryParse(partKey)?.host ?? '') : '';
        if (partKey is String && partKey.isNotEmpty) {
          playable++;
          final hops = await plex.discover.traceExtraPart(partKey);
          appLogger.i('[ReelProbe] catalogue part hops: ${hops.join(' -> ')}');
        }
        appLogger.i(
          '[ReelProbe] catalogue extras: ${extras.length}, keys ${first.keys.toList()}, '
          'subtype ${first['subtype']}, extraType ${first['extraType']}, '
          'part ${partKey is String ? (host.isEmpty ? 'relative ${partKey.split('?').first.replaceAll(RegExp(r'[0-9a-f]{8,}|\d+'), '<id>')}' : 'host $host') : 'none'}',
        );
      } catch (e) {
        appLogger.i('[ReelProbe] catalogue: request failed (${e.runtimeType})');
      }
    }
    appLogger.i(
      '[ReelProbe] catalogue: ${cards.length} shows the servers lack; matched $matched, '
      'with extras $withExtras, with a part key $playable',
    );
  }
}
