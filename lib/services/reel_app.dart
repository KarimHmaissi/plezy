import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../media/ids.dart';
import '../models/companion_remote/remote_command.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../models/catalog/catalog_item.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/companion_remote_provider.dart';
import '../providers/multi_server_provider.dart';
import '../screens/media_detail_screen.dart';
import '../utils/app_logger.dart';
import '../utils/media_image_helper.dart';
import '../utils/platform_detector.dart';
import '../utils/video_player_navigation.dart';
import 'ai/ai_history.dart';
import 'ai/ai_key_store.dart';
import 'ai/ai_spend.dart';
import 'ai/claude_client.dart';
import 'ai/facts/index_title_facts_source.dart';
import 'brain/history_brain.dart';
import 'catalog/home_pins.dart';
import 'catalog/home_rows.dart';
import 'catalog/library_watchlist_candidates.dart';
import 'catalog/trakt_lists_catalog_source.dart';
import 'companion_remote/phone_mode.dart';
import 'customisation/customisation_store.dart';
import 'library_index/library_index.dart';
import 'memory_trim_policy.dart';
import 'multi_server_manager.dart';
import 'reel/clip_player.dart';
import 'reel/clip_resolver.dart';
import 'reel/reel_controller.dart';
import 'reel/reel_decks.dart';
import 'reel/reel_library.dart';
import 'reel/reel_pool.dart';
import 'reel/reel_store.dart';
import 'reel_servers_plex.dart';
import 'trackers/fribb_mapping_store.dart';

/// Fork: builds the Reel's session from the app's real services. Lives
/// outside `lib/services/reel/` and `lib/screens/reel/` because it touches
/// the player navigation and the Plex client, which the Reel itself must
/// never import (test/reel/no_reporting_guard_test.dart).
abstract final class ReelApp {
  /// Saved AI answers offered as decks (newest first).
  static const int answerDecks = 12;

  static Future<ReelController> controller(BuildContext context) async {
    final multi = context.read<MultiServerProvider>();
    final catalog = context.read<CatalogSourcesProvider?>();
    final remote = context.read<CompanionRemoteProvider?>();
    final servers = multi.serverManager;
    final store = ReelStore.instance;
    final facts = IndexTitleFactsSource.app();
    final library = ReelLibrary(database: () => LibraryIndex.instance.database, facts: facts);
    final resolver = resolverFor(servers, store);
    // The TV builds the day's pool and shares it; a phone reads that copy.
    final pool = ReelPool(store: store, library: library, model: _sonnet, host: !PhoneMode.isHandheld);
    final media = _AppReelMedia(servers);
    final resolverRows = catalog == null
        ? null
        : HomeRowResolver(sources: catalog, clientFor: (id) => multi.getClientForServer(id));

    Future<List<MediaItem>> chart(String id) async {
      final r = resolverRows;
      if (r == null) {
        appLogger.i('[ReelDeck] chart $id: no catalogue sources');
        return const [];
      }
      try {
        final hub = await r.fetch((id: id, title: '', sources: const <String>[]));
        appLogger.i('[ReelDeck] chart $id: ${hub == null ? 'no Trakt Lists source' : '${hub.items.length} items'}');
        return hub?.items ?? const [];
      } catch (e) {
        appLogger.i('[ReelDeck] chart $id unavailable (${e.runtimeType})');
        return const [];
      }
    }

    final forYou = ForYouDeck(
      pool: pool,
      library: library,
      candidates: () => forYouCandidates(library: library, store: store),
      facts: () => forYouFacts(store: store, pool: pool),
      again: () => anotherGoCandidates(library: library, store: store),
      sharedChanges: Customisation.changed,
    );
    final decks = <ReelDeck>[
      forYou,
      FitsTonightDeck(forYou: forYou),
      AnotherGoDeck(forYou: forYou, library: library),
      animeOpeningsDeck(library: library, database: () => LibraryIndex.instance.database),
      // The raw charts come from Explore's Trakt Lists source; without Trakt
      // the deck would only ever be empty, so it isn't offered.
      if (catalog?.connectedSources.any((s) => s is TraktListsCatalogSource) ?? false)
        mostWatchedDeck(
          library: library,
          films: () => chart(HomeRowIds.traktLists('chart:watched:movies')),
          shows: () => chart(HomeRowIds.traktLists('chart:watched:shows')),
        ),
      for (final entry in await _answers()) AiAnswerDeck(entry: entry, library: library),
    ];

    // Captured now: the Reel may outlive this build context's frame.
    final navigatorContext = context;

    final controller = ReelController(
      decks: decks,
      resolver: resolver,
      clips: ClipPlayer(),
      store: store,
      media: media,
      onWatch: (item, {required onTv}) async {
        final playable = await _playable(servers.getClient(ServerId(item.serverId ?? '')), item);
        if (playable == null) return false;
        if (onTv) {
          if (remote == null || !remote.isConnected) return false;
          remote.castPlay(playable, initialPosition: Duration.zero);
          return true;
        }
        if (!navigatorContext.mounted) return false;
        final unseenFilm = item.kind == MediaKind.movie && (item.viewOffsetMs ?? 0) == 0;
        await navigateToVideoPlayer(
          navigatorContext,
          metadata: playable,
          initialPosition: unseenFilm ? Duration.zero : null,
          allowCast: false,
        );
        return true;
      },
      addToWatchlist: (item) async {
        final c = catalog;
        if (c == null) return false;
        final client = servers.getClient(ServerId(item.serverId ?? ''));
        final candidates = await c.watchlistCandidatesFor(item, client: client);
        final plex = candidates.where((x) => x.source.id == CatalogSourceId.plex).firstOrNull ?? candidates.firstOrNull;
        if (plex == null) return false;
        return mutateWatchlistMembership(item.kind, plex, add: true);
      },
      onSaved: _seatHomeRow,
      // A phone on its own data reaches the TV by catching up while
      // connected; a mirroring phone writes to the TV (or can't write).
      reachesTvNow: () =>
          !PhoneMode.isHandheld || Customisation.isMirror || (remote != null && remote.isRemote && remote.isConnected),
      // The phone's feed plays each card in its own page; the TV keeps the
      // native clip core.
      externalClips: !PlatformDetector.isTV(),
      // The degrade ladder resets only when the app's caches are restored.
      memoryRestored: MemoryTrimPolicy.instance.restores,
      // Give it another go: the card's one metadata read brings the show's
      // next episode, so Watch can say which.
      itemWithNext: media.itemWithNext,
      onOpen: (item) async {
        if (!navigatorContext.mounted) return;
        await Navigator.of(navigatorContext).push(mediaDetailRoute(metadata: item));
      },
      deckFor: (id) async {
        if (!id.startsWith('ai:')) return null;
        final entry = await AiHistory.get(id.substring(3));
        return entry == null || entry.items.isEmpty ? null : AiAnswerDeck(entry: entry, library: library);
      },
    );
    if (remote != null) _publish(controller, remote);
    // While the Reel plays, the brain's indexer rests and its ONNX session
    // (about 66 MB) is released; it reopens on the next embed. On a day
    // For You gathers its candidates, the brain's similarity reads run
    // first, then it yields.
    var yielded = false;
    // When a session ends, this device shares its Reel signals so the other
    // device's daily build hears them.
    controller.addListener(() {
      if (controller.active == yielded) return;
      yielded = controller.active;
      if (yielded) {
        unawaited(_yieldAfter(forYou, stillActive: () => controller.active));
      } else {
        unawaited(HistoryBrain.instance.yieldTo(false));
        unawaited(pool.signals.publish());
      }
    });
    return controller;
  }

  /// The longest the brain's yield waits for For You's gather.
  static const Duration gatherBeforeYield = Duration(seconds: 8);

  /// Yields the brain to the Reel once For You's gather (when one is due
  /// today) is done, unless the Reel has closed meanwhile.
  static Future<void> _yieldAfter(ForYouDeck forYou, {required bool Function() stillActive}) async {
    try {
      await forYou.prepare().timeout(gatherBeforeYield);
    } catch (_) {
      // Too slow: the gather carries on; the Reel yields now.
    }
    if (stillActive()) await HistoryBrain.instance.yieldTo(true);
  }

  /// Sends the current card to a connected phone at once (it just opened
  /// On TV mode).
  static VoidCallback? republish;

  /// Host side of On TV mode: a `reelState` on every card, deck or play
  /// state change while a phone is connected.
  static void _publish(ReelController c, CompanionRemoteProvider remote) {
    String? last;
    var disposed = false;
    void publish({bool force = false}) {
      if (disposed || !remote.isHost || !remote.isConnected) {
        last = null;
        return;
      }
      final Map<String, Object?> state;
      try {
        state = c.remoteState();
      } catch (_) {
        disposed = true;
        return;
      }
      final key = jsonEncode(state);
      if (!force && key == last) return;
      last = key;
      remote.sendCommand(RemoteCommandType.reelState, data: state);
    }

    c.addListener(publish);
    c.clips.phase.addListener(publish);
    c.cardChanged.addListener(publish);
    republish = () => publish(force: true);
  }

  /// Synced: set once the Reel's Home row has been seated, so removing it in
  /// Manage Home sticks.
  static const String homeRowSeatedKey = 'reel.homeRowSeated';

  /// The first Save puts "From the Reel" at the top of Home, once.
  static Future<void> _seatHomeRow() async {
    final settings = await Customisation.store;
    if (await settings.readSetting(homeRowSeatedKey) != null) {
      appLogger.i('[ReelSave] Home row seated before; left where the user keeps it');
      return;
    }
    final added = await HomePinsController.instance.insertFirst((
      id: HomeRowIds.reelPicks,
      title: 'From the Reel',
      sources: const <String>[],
    ));
    await settings.writeSetting(homeRowSeatedKey, '1');
    appLogger.i('[ReelSave] Home row ${added ? 'seated first' : 'already on Home'}');
  }

  /// The clip resolver over the app's servers (also the measure-day probe).
  static ClipResolver resolverFor(MultiServerManager servers, ReelStore store) =>
      ClipResolver(servers: PlexReelServers(servers), store: store, aniList: _aniList);

  /// Answers worth a deck: the user's own asks, not Tonight or the briefing.
  static Future<List<AiHistoryEntry>> _answers() async {
    try {
      return [
        for (final e in await AiHistory.page(limit: answerDecks + 2))
          if (e.items.length >= 3 && e.id != 'briefing') e,
      ].take(answerDecks).toList();
    } catch (_) {
      return const [];
    }
  }

  /// A film plays itself; a show plays its next unwatched episode, else
  /// S1E1 from the start.
  static Future<MediaItem?> _playable(MediaServerClient? client, MediaItem item) async {
    if (client == null) return null;
    if (item.kind != MediaKind.show) return item;
    try {
      final r = await client.fetchItemWithOnDeck(item.id);
      if (r.onDeckEpisode != null) return r.onDeckEpisode;
      final seasons = await client.fetchChildren(item.id);
      final s1 = seasons.where((s) => s.index == 1).firstOrNull ?? seasons.firstOrNull;
      if (s1 == null) return null;
      final eps = await client.fetchChildren(s1.id);
      return eps.where((e) => e.index == 1).firstOrNull ?? eps.firstOrNull;
    } catch (e) {
      appLogger.w('Reel: could not find an episode to play', error: e);
      return null;
    }
  }

  /// Season 1's AniList id through the Fribb mapping (tvdb, then tmdb).
  static Future<int?> _aniList(ReelTitle t) async {
    try {
      final rows = await FribbMappingStore.instance.lookup(movie: !t.isShow, tvdbId: t.tvdbId, tmdbId: t.tmdbId);
      final s1 = rows.where((r) => r.tvdbSeason == 1 || r.tmdbSeason == 1).firstOrNull ?? rows.firstOrNull;
      return s1?.anilistId;
    } catch (_) {
      return null;
    }
  }

  /// The daily build's output ceiling: about 90 cards, each with an id, a
  /// cluster and optional why, anchor and hook lines (about 7k tokens).
  /// Only the tokens written are billed. It stays well under the size the
  /// API docs say needs streaming (about 21k) and inside the client's
  /// 3-minute timeout. A call cut short ends with `stop_reason` max_tokens
  /// and a truncated tool input
  /// (https://platform.claude.com/docs/en/api/handling-stop-reasons).
  static const int poolMaxTokens = 12000;

  /// The daily build's one Sonnet call (spend recorded like every AI call).
  /// Its `stop_reason` is logged, so a build cut short by the ceiling never
  /// falls back to code order silently.
  static Future<Map<String, dynamic>?> _sonnet(String system, String user, Map<String, Object?> tool) async {
    final key = await AiKeyStore.read();
    if (key == null) return null;
    const model = ClaudeModel.sonnet;
    final client = ClaudeClient(key);
    try {
      final response = await client.createMessage({
        'model': model.id,
        'max_tokens': poolMaxTokens,
        'thinking': model.noThinking,
        'system': system,
        'tools': [tool],
        'tool_choice': model.answerWith(tool['name']! as String),
        'messages': [
          {'role': 'user', 'content': user},
        ],
      });
      final usage = (response['usage'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
      await AiSpend.record(model, usage);
      final stop = response['stop_reason'] as String?;
      final out = usage['output_tokens'];
      if (stop == 'max_tokens') {
        appLogger.w('[ReelPool] build cut short: stop_reason=max_tokens, output $out of $poolMaxTokens tokens');
      } else {
        appLogger.i('[ReelPool] build stop_reason=$stop, output $out tokens');
      }
      return [
        for (final b in (response['content'] as List? ?? const []).whereType<Map>())
          if (b['type'] == 'tool_use') (b['input'] as Map).cast<String, dynamic>(),
      ].firstOrNull;
    } finally {
      client.close();
    }
  }
}

class _AppReelMedia implements ReelMedia {
  _AppReelMedia(this._servers);

  final MultiServerManager _servers;

  MediaServerClient? _client(String serverId) => _servers.getClient(ServerId(serverId));

  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async {
    final c = _client(serverId);
    if (c == null) return null;
    return c.fetchItem(ratingKey).timeout(const Duration(seconds: 15));
  }

  /// The same single metadata read with the on-deck episode included (the
  /// episode [ReelApp._playable] plays).
  Future<({MediaItem? item, MediaItem? next})> itemWithNext(String serverId, String ratingKey) async {
    final c = _client(serverId);
    if (c == null) return (item: null, next: null);
    final r = await c.fetchItemWithOnDeck(ratingKey).timeout(const Duration(seconds: 15));
    return (item: r.item, next: r.onDeckEpisode);
  }

  @override
  String? imageUrl(String serverId, String? path, {required int width}) {
    if (path == null || path.isEmpty) return null;
    final url = MediaImageHelper.getOptimizedImageUrl(
      client: _client(serverId),
      thumbPath: path,
      maxWidth: width.toDouble(),
      maxHeight: width * 9 / 16,
      pixelRatio: 1,
      imageType: ImageType.art,
    );
    return url.isEmpty ? null : url;
  }
}
