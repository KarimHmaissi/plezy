import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
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
import '../screens/reel/reel_card_view.dart';
import '../screens/reel/reel_screen.dart' show ReelScreen;
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
import 'deep_links/deep_link_launcher.dart' show deepLinkServerWait, waitForServers;
import 'device_performance.dart';
import 'library_index/library_index.dart';
import 'memory_trim_policy.dart';
import 'multi_server_manager.dart';
import 'playback_coordinator.dart';
import 'reel/clip_player.dart';
import 'reel/clip_resolver.dart';
import 'reel/reel_controller.dart';
import 'reel/reel_data_budget.dart';
import 'reel/reel_decks.dart';
import 'reel/reel_home_row.dart';
import 'reel/reel_library.dart';
import 'reel/reel_art.dart';
import 'reel/reel_metadata.dart';
import 'reel/reel_person.dart';
import 'reel/reel_playback_profile.dart' hide ReelScreen;
import 'reel/reel_pool.dart';
import 'reel/reel_store.dart';
import 'reel/reel_tmdb.dart';
import 'reel/reel_warmer.dart';
import 'reel_playback_watcher.dart';
import 'reel_servers_plex.dart';
import 'settings_service.dart';
import 'trackers/fribb_mapping_store.dart';

/// Fork: builds the Reel's session from the app's real services. Lives
/// outside `lib/services/reel/` and `lib/screens/reel/` because it touches
/// the player navigation and the Plex client, which the Reel itself must
/// never import (test/reel/no_reporting_guard_test.dart).
abstract final class ReelApp {
  /// Saved AI answers offered as decks (newest first).
  static const int answerDecks = 12;

  /// The decks the Reel offers here, in the app's own order, by id and name
  /// (the Decks screen, V2-52). Builds the deck objects without loading any.
  static Future<List<({String id, String name})>> deckList(BuildContext context) async {
    final shared = _shared(ReelStore.instance);
    final base = await _decks(context, library: shared.library, forYou: shared.forYou);
    return [
      for (final d in [...base, ...await _answerDecks(shared.library)]) (id: d.id, name: d.name),
    ];
  }

  static ({ReelLibrary library, ReelPool pool, ForYouDeck forYou})? _sharedFor;

  /// The library, the day's pool and For You, one set per app run (V2-14):
  /// the warm start before the Reel opens and every Reel session share
  /// them, so a session opened while the warm start gathers or builds joins
  /// that gather and that build (one Sonnet call a day) rather than
  /// starting its own. A new set only if this device stops or starts
  /// building the pool.
  static ({ReelLibrary library, ReelPool pool, ForYouDeck forYou}) _shared(ReelStore store) {
    final have = _sharedFor;
    if (have != null && have.pool.host == !PhoneMode.isHandheld) return have;
    final library = _library();
    final pool = _pool(store, library);
    final forYou = ForYouDeck(
      pool: pool,
      library: library,
      candidates: () => forYouCandidates(library: library, store: store),
      facts: () => forYouFacts(store: store, pool: pool),
      again: () => anotherGoCandidates(library: library, store: store),
      arrivals: () => newThisWeekArrivals(library: library, store: store),
      person: () => personPick(library: library, store: store, pool: pool),
      sharedChanges: Customisation.changed,
      clears: ReelPool.clears,
    );
    return _sharedFor = (library: library, pool: pool, forYou: forYou);
  }

  static ReelLibrary _library() =>
      ReelLibrary(database: () => LibraryIndex.instance.database, facts: IndexTitleFactsSource.app());

  /// The day's For You pool: the TV builds it and shares it; a phone reads
  /// that copy.
  static ReelPool _pool(ReelStore store, ReelLibrary library) =>
      ReelPool(store: store, library: library, model: _sonnet, host: !PhoneMode.isHandheld);

  /// The decks in the app's own order: For You, Fits tonight, Give it
  /// another go, New this week, the Person deck, Anime openings and Most
  /// Watched (with Trakt); the saved answers follow ([_answerDecks]). The controller
  /// applies the user's order and hidden decks
  /// ([ReelController.shownDecks]). For You is always first.
  static Future<List<ReelDeck>> _decks(
    BuildContext context, {
    required ReelLibrary library,
    required ForYouDeck forYou,
  }) async {
    final multi = context.read<MultiServerProvider>();
    final catalog = context.read<CatalogSourcesProvider?>();
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

    return <ReelDeck>[
      forYou,
      FitsTonightDeck(forYou: forYou),
      AnotherGoDeck(forYou: forYou, library: library),
      NewThisWeekDeck(forYou: forYou, library: library),
      PersonDeck(forYou: forYou, library: library),
      animeOpeningsDeck(library: library, database: () => LibraryIndex.instance.database),
      // The raw charts come from Explore's Trakt Lists source; without Trakt
      // the deck would only ever be empty, so it isn't offered.
      if (catalog?.connectedSources.any((s) => s is TraktListsCatalogSource) ?? false)
        mostWatchedDeck(
          library: library,
          films: () => chart(HomeRowIds.traktLists('chart:watched:movies')),
          shows: () => chart(HomeRowIds.traktLists('chart:watched:shows')),
        ),
    ];
  }

  /// The saved answers as decks (newest first). The Reel adds them once its
  /// first card has shown (V2-04), so reading them never holds up its open.
  static Future<List<ReelDeck>> _answerDecks(ReelLibrary library) async => [
    for (final entry in await _answers()) AiAnswerDeck(entry: entry, library: library),
  ];

  static Future<ReelController> controller(BuildContext context) async {
    final multi = context.read<MultiServerProvider>();
    final catalog = context.read<CatalogSourcesProvider?>();
    final remote = context.read<CompanionRemoteProvider?>();
    final servers = multi.serverManager;
    final store = ReelStore.instance;
    // A Reel session is starting: the warm start's steps still to come are
    // dropped (V2-14).
    _warmer?.yieldNow();
    final shared = _shared(store);
    final library = shared.library;
    final pool = shared.pool;
    final forYou = shared.forYou;
    final resolver = resolverFor(
      servers,
      store,
      serversChanged: multi,
      profile: ReelPlaybackWatcher.instance,
      tmdb: _tmdbRung(ReelPlaybackWatcher.instance),
    );
    final media = _AppReelMedia(servers, store);
    final decks = await _decks(context, library: library, forYou: forYou);
    // The Person deck names today's person before its first load, without
    // holding up the open.
    for (final d in decks.whereType<PersonDeck>()) {
      unawaited(d.peek());
    }

    // Captured now: the Reel may outlive this build context's frame.
    final navigatorContext = context;

    // Whether the Reel is playing, as its onActive hook last said.
    var active = false;
    final controller = ReelController(
      decks: decks,
      resolver: resolver,
      // The mute is kept across launches (V2-22), and the TV's clip plays
      // as often as the clip-end pref says (V2-47). The TV's player is built
      // muted: each visit settles its sound before the first card plays
      // (ReelScreen._visit), so nothing is ever heard before that.
      clips: ClipPlayer(
        muted: PlatformDetector.isTV() || (SettingsService.instanceOrNull?.read(SettingsService.reelMuted) ?? false),
        plays: () => ReelController.clipEndPref().plays,
      ),
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
      // The TV seats "From the Reel" on its Home; a phone's Save writes
      // only the pick (see ReelHomeRow).
      onSaved: () => ReelHomeRow.seat(),
      // A phone on its own data reaches the TV by catching up while
      // connected; a mirroring phone writes to the TV (or can't write).
      reachesTvNow: () =>
          !PhoneMode.isHandheld || Customisation.isMirror || (remote != null && remote.isRemote && remote.isConnected),
      // The phone's feed plays each card in its own page; the TV keeps the
      // native clip core.
      externalClips: !PlatformDetector.isTV(),
      // TV cold open (V2-04): the clip core comes up alongside the deck, the
      // card the Reel was left on opens at once (matched from the local
      // index only), and the saved answers join after the first card.
      warmClipCore: PlatformDetector.isTV(),
      headCard: PlatformDetector.isTV() ? (entry) async => (await library.cards([entry])).firstOrNull : null,
      moreDecks: () => _answerDecks(library),
      // Each deck carries on where it was left today, on both devices
      // (V2-14).
      keepCursor: true,
      // The degrade ladder resets only when the app's caches are restored.
      memoryRestored: MemoryTrimPolicy.instance.restores,
      // While the Reel plays, the brain's indexer rests and its ONNX session
      // (about 66 MB) is released; it reopens on the next embed. On a day
      // For You gathers its candidates, the brain's similarity reads run
      // first, then it yields. The hook also fires when the Reel is disposed
      // while playing (V2-60), so the indexer never stays parked. When a
      // session ends, this device shares its Reel signals so the other
      // device's daily build hears them.
      onActive: (on) {
        active = on;
        _warmer?.reelActive(on);
        if (on) {
          unawaited(_yieldAfter(forYou, stillActive: () => active));
        } else {
          unawaited(HistoryBrain.instance.yieldTo(false));
          unawaited(pool.signals.publish());
        }
      },
      // Give it another go: the card's one metadata read brings the show's
      // next episode, so Watch can say which.
      itemWithNext: media.itemWithNext,
      // The Reel's settings page applies to the Reel that is playing.
      settingsChanged: SettingsService.instanceOrNull?.listenableOfAll(SettingsService.reelChoicePrefs),
      // The Reel on mobile data (V2-53): the pref. The link itself is the
      // playback profile's (the resolver's ReelPlaybackWatcher), the one
      // reading the data budget and the clip's file both follow.
      cellular: () =>
          SettingsService.instanceOrNull?.read(SettingsService.reelCellular) ??
          SettingsService.reelCellular.resolvedDefault,
      onOpen: (item) async {
        if (!navigatorContext.mounted) return;
        await Navigator.of(navigatorContext).push(mediaDetailRoute(metadata: item));
      },
      // More like this (V2-39): the build's prompt over titles like the
      // card, one call per press, its spend logged per press.
      moreLike: (seed, {required skip}) => moreLikeCards(
        seed,
        pool: pool,
        library: library,
        facts: () => forYouFacts(store: store, pool: pool),
        call: _moreLikeSonnet,
        skip: skip,
      ),
      deckFor: (id) async {
        if (!id.startsWith('ai:')) return null;
        final entry = await AiHistory.get(id.substring(3));
        return entry == null || entry.items.isEmpty ? null : AiAnswerDeck(entry: entry, library: library);
      },
    );
    if (remote != null) _publish(controller, remote);
    _sweepLater(store);
    return controller;
  }

  /// How long after the Reel opens the daily sweep waits, so it never
  /// competes with the open's own cache reads.
  static const Duration sweepDelay = Duration(seconds: 30);

  /// The Reel's cache housekeeping ([ReelStore.sweep]), at most once a day.
  /// On the TV the warm start before the Reel opens (V2-14) runs it too;
  /// whichever comes first that day does it.
  static void _sweepLater(ReelStore store) => Timer(sweepDelay, () async {
    try {
      final s = await store.sweep();
      if (s == null) return;
      appLogger.i(
        '[ReelCache] daily sweep: ${s.pools} pool, ${s.days} deck/cursor, '
        '${s.sources} source rows, ${s.metas} metadata rows, ${s.events} events',
      );
    } catch (e) {
      appLogger.w('[ReelCache] daily sweep failed', error: e);
    }
  });

  static ReelWarmer? _warmer;

  /// The Home the warm start decodes art through: the latest one armed
  /// from, so a Home built again (a profile switch) replaces the one gone.
  static BuildContext? _warmContext;

  /// TV, from the app's post-startup idle point (Home's background start,
  /// after the library index): arms the warm start before the Reel opens
  /// (V2-14), once per app run, while the Reel is turned on. It never runs
  /// while a video plays, in the background or with the Reel open, and
  /// reads no server but for the first card's art.
  static void warmBeforeOpen(BuildContext context) {
    if (!PlatformDetector.isTV() || !ReelScreen.enabled) return;
    _warmContext = context;
    if (_warmer != null) return;
    final servers = context.read<MultiServerProvider>().serverManager;
    final store = ReelStore.instance;
    final media = _AppReelMedia(servers, store);
    _warmer = ReelWarmer(
      store: store,
      forYou: _shared(store).forYou,
      playing: () => PlaybackCoordinator.instance.hasVideoSession,
      foreground: () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      cachedItem: media.cachedItem,
      // Decoded as the TV's card view builds it, through the latest Home's
      // context (the same screen size); with no Home mounted it isn't, and
      // the done line says art=failed.
      precacheArt: (card, item, {required clip}) async {
        final home = _warmContext;
        if (home == null || !home.mounted) throw StateError('Home is not mounted');
        await ReelCardView.precacheArt(home, card, item, clip: clip);
      },
      // Not while a memory trim has the Reel's art budget cut.
      artAllowed: () => ReelArt.budgetBytes() >= DevicePerformance.reelImageBudgetBytes(),
    )..arm();
    appLogger.i('[ReelWarmer] armed');
  }

  /// Settings' "Rebuild today's For You" ([ReelPool.clearToday]), with the
  /// same host rule as the Reel's own pool. Returns whether this device does
  /// the rebuild; false on a phone whose TV builds For You.
  static Future<bool> rebuildForYouToday() => ReelPool(
    store: ReelStore.instance,
    library: ReelLibrary(database: () => LibraryIndex.instance.database, facts: IndexTitleFactsSource.app()),
    host: !PhoneMode.isHandheld,
  ).clearToday();

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
  /// On TV mode), from the session the screen holds. A session build that
  /// ran past the screen's 30 s build limit can land after a second build was
  /// started; whichever the screen discards is disposed, so it is skipped
  /// here, and the one kept is forced however the builds finished.
  static void republish() {
    _publishers.removeWhere((p) => p.controller.isDisposed);
    for (final p in [..._publishers]) {
      p.force();
    }
  }

  /// One On TV publisher per session build still alive, oldest first.
  static final List<({ReelController controller, VoidCallback force})> _publishers = [];

  /// Tests: forgets every publisher.
  @visibleForTesting
  static void debugResetPublishers() => _publishers.clear();

  /// Host side of On TV mode: a `reelState` on every card, deck or play
  /// state change while a phone is connected.
  static void _publish(ReelController c, CompanionRemoteProvider remote) => publishState(
    c,
    connected: () => remote.isHost && remote.isConnected,
    send: (state) => remote.sendCommand(RemoteCommandType.reelState, data: state),
  );

  /// [_publish] over plain hooks (the run-time seam for tests): [send]
  /// gets [ReelController.remoteState] on every change while [connected],
  /// never twice the same unless [republish] forces it, and nothing once
  /// [c] is disposed.
  @visibleForTesting
  static void publishState(
    ReelController c, {
    required bool Function() connected,
    required void Function(Map<String, Object?> state) send,
  }) {
    String? last;
    var disposed = false;
    void publish({bool force = false}) {
      if (disposed || c.isDisposed) {
        disposed = true;
        return;
      }
      if (!connected()) {
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
      send(state);
    }

    c.addListener(publish);
    c.clips.phase.addListener(publish);
    c.cardChanged.addListener(publish);
    _publishers
      ..removeWhere((p) => p.controller.isDisposed)
      ..add((controller: c, force: () => publish(force: true)));
  }

  /// The clip resolver over the app's servers (also the measure-day probe).
  /// With [serversChanged], a server that isn't connected yet is waited for
  /// as long as a deep link waits ([deepLinkServerWait]), once per start or
  /// resume: after a wake the Reel opens before the servers reconnect. With
  /// [profile], a clip's file is picked for the device as it is now (plan
  /// V2-16); without it, by the standard profile.
  static ClipResolver resolverFor(
    MultiServerManager servers,
    ReelStore store, {
    Listenable? serversChanged,
    ValueListenable<ReelPlaybackProfile>? profile,
    ReelTmdbRung? tmdb,
  }) {
    final plex = PlexReelServers(servers);
    return ClipResolver(
      servers: plex,
      store: store,
      aniList: _aniList,
      profile: profile,
      tmdb: tmdb,
      waitForServer: serversChanged == null
          ? null
          : (id) => waitForServers(serversChanged, () => plex.connected(id), timeout: deepLinkServerWait),
    );
  }

  /// The TMDB trailer rung (plan V2-63, D16): Android phones only (the
  /// feed plays it in a WebView; the TV has none, so its clip-less titles
  /// stay AI cards with a premise). It runs while [tmdbRungMayRun] says so.
  /// The TMDB key is the one in Settings ▸ AI; with none set the rung is
  /// skipped.
  static ReelTmdbRung? _tmdbRung(ValueListenable<ReelPlaybackProfile> profile) {
    if (PlatformDetector.isTV() || !Platform.isAndroid) return null;
    final client = TmdbVideosClient();
    unawaited(client.prime());
    return ReelTmdbRung(
      fetch: client.fetch,
      on: () => tmdbRungMayRun(
        mayHaveKey: client.mayHaveKey,
        profile: profile.value,
        cellular:
            SettingsService.instanceOrNull?.read(SettingsService.reelCellular) ??
            SettingsService.reelCellular.resolvedDefault,
      ),
      language: () => LocaleSettings.currentLocale.languageCode,
    );
  }

  /// Whether the TMDB rung may run now: a key may be set, and the data
  /// budget is full (Wi-Fi, or mobile data on Normal; Data saver and Stills
  /// only turn it off, V2-53). The link is the playback [profile]'s, the one
  /// source the controller's data budget and the clip picks read too, so the
  /// rung never disagrees with them while the network changes.
  @visibleForTesting
  static bool tmdbRungMayRun({
    required bool mayHaveKey,
    required ReelPlaybackProfile profile,
    required ReelCellular cellular,
  }) => mayHaveKey && ReelDataBudget.of(cellular, metered: profile.link == ReelLink.cellular) == ReelDataBudget.full;

  /// The cards' metadata and art over the app's servers, for the run-time
  /// seam test (V2-62).
  @visibleForTesting
  static ReelMedia mediaFor(MultiServerManager servers, ReelStore store) => _AppReelMedia(servers, store);

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
  /// Throws when the mapping itself couldn't be read, so the resolver
  /// counts the title as unknown rather than caching a miss.
  static Future<int?> _aniList(ReelTitle t) async {
    final fribb = FribbMappingStore.instance;
    final rows = await fribb.lookup(movie: !t.isShow, tvdbId: t.tvdbId, tmdbId: t.tmdbId);
    if (rows.isEmpty && !await fribb.available()) throw StateError('Fribb mapping unavailable');
    final s1 = rows.where((r) => r.tvdbSeason == 1 || r.tmdbSeason == 1).firstOrNull ?? rows.firstOrNull;
    return s1?.anilistId;
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
  static Future<Map<String, dynamic>?> _sonnet(String system, String user, Map<String, Object?> tool) =>
      _claude(system, user, tool, what: '[ReelPool] build');

  /// One More like this press (V2-39): the build's prompt and ceiling over
  /// 40 candidates. No cost figure is assumed; each press logs its tokens
  /// and its cost (AiSpend), so the first runs say what a press costs.
  static Future<Map<String, dynamic>?> _moreLikeSonnet(String system, String user, Map<String, Object?> tool) =>
      _claude(system, user, tool, what: '[ReelMore] press');

  static Future<Map<String, dynamic>?> _claude(
    String system,
    String user,
    Map<String, Object?> tool, {
    required String what,
  }) async {
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
      final cost = await AiSpend.record(model, usage);
      final stop = response['stop_reason'] as String?;
      final out = usage['output_tokens'];
      final spent = 'input ${usage['input_tokens']} tokens, cost \$${cost.toStringAsFixed(4)}';
      if (stop == 'max_tokens') {
        appLogger.w('$what cut short: stop_reason=max_tokens, output $out of $poolMaxTokens tokens, $spent');
      } else {
        appLogger.i('$what stop_reason=$stop, output $out tokens, $spent');
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
  _AppReelMedia(this._servers, ReelStore store) : _plex = PlexReelMetadata(_servers) {
    _metadata = ReelMetadata(source: _plex, store: store);
  }

  final MultiServerManager _servers;
  final PlexReelMetadata _plex;
  late final ReelMetadata _metadata;

  MediaServerClient? _client(String serverId) => _servers.getClient(ServerId(serverId));

  /// Plex: cache-first, else one lean read (plan V2-03). Other backends keep
  /// their own item read.
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async {
    if (_plex.serves(serverId)) return _metadata.item(serverId, ratingKey);
    return fullItem(serverId, ratingKey);
  }

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) async {
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

  /// The item from the caches alone (the warm start, V2-14): Plex only.
  Future<MediaItem?> cachedItem(String serverId, String ratingKey) async =>
      _plex.serves(serverId) ? _metadata.cachedItem(serverId, ratingKey) : null;

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
