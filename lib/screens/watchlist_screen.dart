import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/focusable_action_bar.dart';
import '../focus/hub_vertical_navigation.dart';
import '../focus/locked_hub_controller.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../mixins/refreshable.dart';
import '../mixins/tab_visibility_aware.dart';
import '../models/catalog/catalog_item.dart';
import '../navigation/main_screen_scope.dart';
import '../providers/catalog_sources_provider.dart';
import '../services/catalog/catalog_source.dart';
import '../services/catalog/watchlist_genres.dart';
import '../services/catalog/watchlist_split.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/hub_section.dart';
import '../widgets/settings_builder.dart';
import '../widgets/toolbar_scrim.dart';
import '../widgets/tv_browse_rail.dart';
import '../widgets/tv_spotlight_scaffold.dart';
import 'libraries/state_messages.dart';
import '../services/catalog/home_pins.dart';
import '../widgets/home_row_actions.dart';
import '../widgets/media_context_menu.dart' show MediaMenuExtraEntry;

/// The Watchlist tab: the user's catalog watchlist as genre shelves, Films
/// first, then TV.
///
/// Genres are looked up automatically for every title at load time (see
/// [resolveWatchlistGenres]); until they arrive the page shows plain Films
/// and TV shelves.
///
/// Reads the watchlist of Explore's active source when it has one, otherwise
/// the first connected source that does (see
/// [CatalogSourcesProvider.watchlistCapableSources]). Items are catalog
/// stand-ins, so opening one goes through the catalog detail screen, which
/// resolves where the title is available in the user's libraries.
class WatchlistScreen extends StatefulWidget {
  const WatchlistScreen({super.key});

  @override
  State<WatchlistScreen> createState() => WatchlistScreenState();
}

class WatchlistScreenState extends State<WatchlistScreen>
    with ManualRefreshable, FullRefreshable, TabVisibilityAware, FocusableTab {
  static const int _pageLimit = 100;
  static const int _maxPages = 5;

  /// The tab reloads when shown after this long.
  static const Duration _staleAfter = Duration(minutes: 5);

  /// Watchlist mutations notify before the API call settles; wait out the
  /// burst before refetching.
  static const Duration _mutationRefreshDelay = Duration(seconds: 1);

  /// A genre needs at least this many titles for its own shelf; smaller ones
  /// fold into "Other Films" / "Other TV".
  static const int _minGenreShelfSize = 6;

  late CatalogSourcesProvider _sources;
  CatalogSource? _source;
  WatchlistSplit _split = (films: const [], tv: const []);

  /// Genre shelves for [_split], or null until genres have been resolved.
  List<WatchlistGenreGroup>? _genreGroups;
  bool _loading = false;
  bool _loaded = false;
  Object? _error;
  DateTime? _loadedAt;
  int _generation = 0;
  Timer? _mutationRefreshTimer;

  final _actionBarKey = GlobalKey<FocusableActionBarState>();
  final _tvBrowseRailKey = GlobalKey<TvBrowseRailState>();
  final _hubFocusMemory = HubFocusMemory();
  final TvSpotlightController _spotlight = TvSpotlightController();
  final ValueNotifier<bool> _tvRowsExpanded = ValueNotifier(false);
  final List<GlobalKey<HubSectionState>> _hubKeys = [GlobalKey()];

  @override
  void initState() {
    super.initState();
    _sources = context.read<CatalogSourcesProvider>();
    _sources.addListener(_onSourcesChanged);
    _onSourcesChanged();
  }

  @override
  void dispose() {
    _sources.removeListener(_onSourcesChanged);
    _source?.watchlistChanges.removeListener(_onWatchlistChanged);
    _mutationRefreshTimer?.cancel();
    _spotlight.dispose();
    _tvRowsExpanded.dispose();
    super.dispose();
  }

  CatalogSource? _pickSource() {
    final active = _sources.activeSource;
    if (active != null && active.supportsWatchlist) return active;
    return _sources.watchlistCapableSource;
  }

  void _onSourcesChanged() {
    final next = _pickSource();
    if (identical(next, _source)) return;
    _source?.watchlistChanges.removeListener(_onWatchlistChanged);
    _source = next;
    _source?.watchlistChanges.addListener(_onWatchlistChanged);
    _generation++;
    _split = (films: const [], tv: const []);
    _genreGroups = null;
    _loaded = false;
    _error = null;
    _loadedAt = null;
    if (mounted) setState(() {});
    if (next != null) unawaited(_load());
  }

  void _onWatchlistChanged() {
    _mutationRefreshTimer?.cancel();
    _mutationRefreshTimer = Timer(_mutationRefreshDelay, () => unawaited(_load()));
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = <CatalogItem>[];
      for (var page = 1; page <= _maxPages; page++) {
        final result = await source.fetchRow(CatalogRowId.watchlist, page: page, limit: _pageLimit);
        items.addAll(result.items);
        if (!result.hasMore) break;
        if (page == _maxPages) appLogger.w('Watchlist: truncated at ${items.length} items ($page pages)');
      }
      if (!mounted || generation != _generation) return;
      final split = splitWatchlist(items);
      setState(() {
        _split = split;
        _loaded = true;
        _loadedAt = DateTime.now();
      });
      unawaited(_groupByGenre(source, split, generation));
    } catch (e) {
      appLogger.w('Watchlist: ${source.id.name} load failed', error: e);
      if (!mounted || generation != _generation) return;
      // Keep the last good list on a failed refresh; only an empty page
      // shows the error.
      setState(() => _error = e);
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _groupByGenre(CatalogSource source, WatchlistSplit split, int generation) async {
    try {
      final cache = await WatchlistGenreCache.load();
      final genres = await resolveWatchlistGenres(
        [...split.films, ...split.tv],
        lookup: source is CatalogGenreLookup ? source as CatalogGenreLookup : null,
        cache: cache,
      );
      unawaited(cache.save());
      if (!mounted || generation != _generation) return;
      setState(
        () => _genreGroups = groupWatchlistByGenre(split, (item) => genres[item], minGroupSize: _minGenreShelfSize),
      );
    } catch (e) {
      appLogger.w('Watchlist: genre grouping failed', error: e);
    }
  }

  @override
  void manualRefresh() => unawaited(_load());

  @override
  void fullRefresh() => unawaited(_load());

  @override
  void onTabShown() {
    final loadedAt = _loadedAt;
    if (!_loading && (loadedAt == null || DateTime.now().difference(loadedAt) > _staleAfter)) {
      unawaited(_load());
    }
  }

  @override
  void onTabHidden() {}

  @override
  void focusActiveTabIfReady() {
    if (PlatformDetector.isTV()) {
      if (_hubs.isNotEmpty) {
        _tvBrowseRailKey.currentState?.requestFocus();
      } else {
        _actionBarKey.currentState?.requestFocusOnFirst();
      }
      return;
    }
    _hubKeys.first.currentState?.requestFocusFromMemory();
  }

  List<MediaHub> get _hubs {
    final source = _source;
    if (source == null) return const [];
    MediaHub hub(String id, String title, List<CatalogItem> items) => MediaHub(
      id: 'watchlist:${source.id.name}:$id',
      identifier: 'watchlist.$id',
      title: title,
      type: 'mixed',
      items: [for (final item in items) item.toMediaItem()],
      size: items.length,
    );
    final groups = _genreGroups;
    if (groups == null) {
      return [
        if (_split.films.isNotEmpty) hub('films', t.watchlist.films, _split.films),
        if (_split.tv.isNotEmpty) hub('tv', t.watchlist.tv, _split.tv),
      ];
    }
    return [
      for (final group in groups)
        hub('${group.films ? 'films' : 'tv'}.${group.genre ?? 'other'}', switch ((group.films, group.genre)) {
          (true, final String genre) => t.watchlist.genreFilms(genre: genre),
          (false, final String genre) => t.watchlist.genreTv(genre: genre),
          (true, null) => t.watchlist.otherFilms,
          (false, null) => t.watchlist.otherTv,
        }, group.items),
    ];
  }

  /// Each shelf (and the whole Films / TV split) can be added to Home.
  List<MediaMenuExtraEntry> _homeRowMenuEntriesFor(MediaHub hub) {
    final source = _source;
    final prefix = 'watchlist:${source?.id.name}:';
    if (source == null || !hub.id.startsWith(prefix)) return const [];
    final shelf = hub.id.substring(prefix.length);
    final split = shelf.split('.').first;
    final entries = homeRowMenuEntries(context, (id: HomeRowIds.watchlist(shelf), title: hub.title, sources: const []));
    if (entries.isEmpty || shelf == split) return entries;
    // A genre shelf also offers its whole half.
    final half = split == 'films' ? t.watchlist.films : t.watchlist.tv;
    final halfEntry = homeRowMenuEntries(context, (
      id: HomeRowIds.watchlist(split),
      title: half,
      sources: const [],
    )).first;
    return [
      entries.first,
      MediaMenuExtraEntry(icon: halfEntry.icon, label: '${halfEntry.label}: $half', onSelected: halfEntry.onSelected),
      ...entries.skip(1),
    ];
  }

  static IconData _iconFor(MediaHub hub) =>
      hub.identifier?.startsWith('watchlist.films') ?? false ? Symbols.movie_rounded : Symbols.tv_rounded;

  void _setSpotlightItem(MediaItem item) => _spotlight.select(item);

  void _navigateToSidebar() => MainScreenFocusScope.focusSidebarOf(context);

  Widget? _buildStateMessage() {
    if (_source == null) {
      return EmptyStateWidget(
        message: t.watchlist.noSourceTitle,
        subtitle: t.watchlist.noSourceMessage,
        icon: Symbols.bookmark_rounded,
      );
    }
    if (!_loaded && _error == null) return const Center(child: CircularProgressIndicator());
    if (!_loaded && _error != null) {
      return ErrorStateWidget(
        message: _error.toString(),
        icon: Symbols.error_outline_rounded,
        onRetry: () => unawaited(_load()),
      );
    }
    if (_split.films.isEmpty && _split.tv.isEmpty) {
      return EmptyStateWidget(
        message: t.watchlist.emptyTitle,
        subtitle: t.watchlist.emptyMessage(source: _source!.displayName),
        icon: Symbols.bookmark_rounded,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<CatalogSourcesProvider>();
    final hubs = _hubs;
    if (PlatformDetector.isTV()) {
      return SettingsBuilder(
        prefs: const [SettingsService.hideSpoilers, SettingsService.libraryDensity, SettingsService.episodePosterMode],
        builder: (context) => _buildTvContent(hubs),
      );
    }
    return _buildDesktopContent(hubs);
  }

  Widget _buildTvContent(List<MediaHub> hubs) {
    final message = _buildStateMessage();
    final foregroundColor = Theme.of(context).colorScheme.onSurface;
    return TvSpotlightScaffold(
      hubs: hubs,
      spotlightListenable: _spotlight,
      resolveSpotlight: () => _spotlight.resolve(hubs),
      resolveClient: (spotlight) => context.tryGetMediaClientForServer(serverIdOrNull(spotlight?.serverId)),
      condensedListenable: _tvRowsExpanded,
      foreground: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          ?message,
          if (hubs.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: TvBrowseRail(
                key: _tvBrowseRailKey,
                hubs: hubs,
                focusMemory: _hubFocusMemory,
                iconForHub: (hub, _) => _iconFor(hub),
                onFocusedItemChanged: _setSpotlightItem,
                onNavigateUp: _actionBarKey.currentState?.requestFocusOnFirst,
                onNavigateToSidebar: _navigateToSidebar,
                onBack: _navigateToSidebar,
                tallPosterScale: TvBrowseRailLayout.compactTallPosterScale,
                widePosterScale: TvBrowseRailLayout.compactEpisodeThumbnailScale,
                expandedTop: TvSpotlightScaffold.condensedRailTopFor(MediaQuery.sizeOf(context)),
                onExpandedChanged: (expanded) => _tvRowsExpanded.value = expanded,
                rowMenuEntriesForHub: _homeRowMenuEntriesFor,
              ),
            ),
          TvToolbarOverlay(
            child: ToolbarScrim(
              child: Row(
                children: [
                  const Spacer(),
                  FocusableActionBar(
                    key: _actionBarKey,
                    onNavigateLeft: _navigateToSidebar,
                    onNavigateDown: _tvBrowseRailKey.currentState?.requestFocus,
                    onBack: _navigateToSidebar,
                    actions: [
                      FocusableAction(
                        icon: Symbols.refresh_rounded,
                        iconColor: foregroundColor,
                        tooltip: t.common.refresh,
                        onPressed: manualRefresh,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopContent(List<MediaHub> hubs) {
    final message = _buildStateMessage();
    while (_hubKeys.length < hubs.length) {
      _hubKeys.add(GlobalKey());
    }
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            DesktopSliverAppBar(
              title: Text(t.navigation.watchlist),
              pinned: false,
              floating: true,
              snap: true,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              surfaceTintColor: Colors.transparent,
              shadowColor: Colors.transparent,
              scrolledUnderElevation: 0,
              actions: [
                FocusableActionBar(
                  key: _actionBarKey,
                  onNavigateDown: () => _hubKeys.first.currentState?.requestFocusFromMemory(),
                  actions: [
                    FocusableAction(icon: Symbols.refresh_rounded, tooltip: t.common.refresh, onPressed: manualRefresh),
                  ],
                ),
              ],
            ),
            if (message != null)
              SliverFillRemaining(child: message)
            else ...[
              for (var i = 0; i < hubs.length; i++)
                SliverToBoxAdapter(
                  child: HubSection(
                    key: _hubKeys[i],
                    hub: hubs[i],
                    focusMemory: _hubFocusMemory,
                    icon: _iconFor(hubs[i]),
                    onVerticalNavigation: (isUp) => navigateVerticalHubRows(
                      hubCount: hubs.length,
                      hubIndex: i,
                      isUp: isUp,
                      onTopBoundary: () => _actionBarKey.currentState?.requestFocusOnFirst(),
                      requestFocus: (target) => _hubKeys[target].currentState?.requestFocusFromMemory(),
                    ),
                    onNavigateToSidebar: _navigateToSidebar,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
            ],
          ],
        ),
      ),
    );
  }
}
