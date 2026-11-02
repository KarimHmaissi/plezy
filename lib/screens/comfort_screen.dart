import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'settings/trakt_settings_screen.dart';
import '../widgets/phone_nav_drawer.dart';
import '../focus/focusable_action_bar.dart';
import '../focus/hub_vertical_navigation.dart';
import '../focus/locked_hub_controller.dart';
import '../i18n/strings.g.dart';
import '../media/episode_collection.dart';
import '../media/ids.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../mixins/refreshable.dart';
import '../mixins/tab_visibility_aware.dart';
import '../models/catalog/catalog_item.dart';
import '../navigation/main_screen_scope.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/discover_provider.dart';
import '../services/continue_watching/continue_watching_classifier.dart';
import '../services/catalog/catalog_library_matcher.dart';
import '../services/catalog/trakt_catalog_source.dart';
import '../services/customisation/customisation_store.dart';
import '../services/comfort/comfort_picker.dart';
import '../services/comfort/comfort_shows_controller.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../utils/video_player_navigation.dart';
import '../widgets/app_icon.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/dialog_action_button.dart';
import '../widgets/hub_section.dart';
import '../widgets/settings_builder.dart';
import '../widgets/toolbar_scrim.dart';
import '../widgets/tv_browse_rail.dart';
import '../widgets/tv_spotlight_scaffold.dart';
import 'comfort_configure_screen.dart';
import 'libraries/state_messages.dart';
import '../services/catalog/home_pins.dart';
import '../widgets/home_row_actions.dart';
import '../widgets/media_context_menu.dart' show MediaMenuExtraEntry;
import '../theme/fork_motion.dart';

enum _PickChoice { play, again }

/// The Comfort tab: the user's comfort shows (one private Trakt list) and a
/// Random episode action that plays a random episode from the shows in the
/// mix, giving each show an equal chance. Configure toggles shows in and out
/// of the mix; that state lives in the Trakt list's description so it
/// follows the user across devices.
class ComfortScreen extends StatefulWidget {
  const ComfortScreen({super.key});

  @override
  State<ComfortScreen> createState() => ComfortScreenState();
}

class ComfortScreenState extends State<ComfortScreen>
    with ManualRefreshable, FullRefreshable, TabVisibilityAware, FocusableTab {
  /// The tab reloads the Trakt list when shown after this long.
  static const Duration _staleAfter = Duration(minutes: 5);

  late CatalogSourcesProvider _sources;

  /// Home's on-deck items: part-watched comfort episodes come from here.
  DiscoverProvider? _discover;
  static const String _carryOnHubId = 'comfort:carryon';
  ComfortShowsController? _controller;
  DateTime? _loadedAt;
  bool _picking = false;

  /// Local episodes per show (keyed by identity), so Pick again is instant.
  final Map<String, List<MediaItem>> _episodesByShow = {};

  final _actionBarKey = GlobalKey<FocusableActionBarState>();
  final _tvBrowseRailKey = GlobalKey<TvBrowseRailState>();
  final _hubFocusMemory = HubFocusMemory();
  final TvSpotlightController _spotlight = TvSpotlightController();
  final ValueNotifier<bool> _tvRowsExpanded = ValueNotifier(false);
  final List<GlobalKey<HubSectionState>> _hubKeys = [GlobalKey(), GlobalKey()];

  @override
  void initState() {
    super.initState();
    _sources = context.read<CatalogSourcesProvider>();
    _sources.addListener(_onSourcesChanged);
    Customisation.changed.addListener(_onCustomisationChanged);
    _discover = context.read<DiscoverProvider?>()?..addListener(_onDiscoverChanged);
    _onSourcesChanged();
  }

  List<MediaItem>? _seenOnDeck;

  void _onDiscoverChanged() {
    final onDeck = _discover?.onDeck;
    if (identical(onDeck, _seenOnDeck)) return;
    _seenOnDeck = onDeck;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sources.removeListener(_onSourcesChanged);
    Customisation.changed.removeListener(_onCustomisationChanged);
    _discover?.removeListener(_onDiscoverChanged);
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _spotlight.dispose();
    _tvRowsExpanded.dispose();
    super.dispose();
  }

  TraktCatalogSource? get _traktSource => _sources.connectedSources.whereType<TraktCatalogSource>().firstOrNull;

  /// With Trakt, the live list; without (a phone), the copy the Trakt
  /// device keeps, which a phone mirroring the TV/Mac receives with its
  /// snapshot.
  void _onSourcesChanged() {
    final source = _traktSource;
    final wantsLive = source != null;
    if (_controller != null && _controller!.canEditList == wantsLive) return;
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _controller = (wantsLive ? ComfortShowsController(source) : ComfortShowsController.cached())
      ..addListener(_onControllerChanged);
    unawaited(_load());
  }

  /// A new mirror snapshot (or an edit applied here): re-read the cached list.
  void _onCustomisationChanged() {
    if (_controller?.canEditList == false) unawaited(_load());
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final controller = _controller;
    if (controller == null) return;
    _episodesByShow.clear();
    await controller.load();
    _loadedAt = DateTime.now();
  }

  @override
  void manualRefresh() => unawaited(_load());

  @override
  void fullRefresh() => unawaited(_load());

  @override
  void onTabShown() {
    final loadedAt = _loadedAt;
    if (_controller != null && (loadedAt == null || DateTime.now().difference(loadedAt) > _staleAfter)) {
      unawaited(_load());
    }
  }

  @override
  void onTabHidden() {}

  @override
  void focusActiveTabIfReady() {
    if (PlatformDetector.isTV()) {
      _actionBarKey.currentState?.requestFocusOnFirst();
      return;
    }
    _hubKeys.first.currentState?.requestFocusFromMemory();
  }

  // --- Random episode -------------------------------------------------------

  Future<List<MediaItem>> _localEpisodes(CatalogItem show) async {
    final cached = _episodesByShow[show.identityKey];
    if (cached != null) return cached;
    final result = await context.read<CatalogLibraryMatcher>().match(show);
    final localShow = result.items.where((item) => item.kind == MediaKind.show).firstOrNull;
    if (localShow == null || !mounted) return const [];
    final client = context.getMediaClientForItemOrNull(localShow);
    if (client == null) return const [];
    final episodes = <MediaItem>[];
    await collectEpisodes(client, localShow.id, unwatchedOnly: false, out: episodes, includeSpecials: false);
    _episodesByShow[show.identityKey] = episodes;
    return episodes;
  }

  static bool _isRecentlyWatched(MediaItem episode) =>
      watchedWithin(episode.lastViewedAt, comfortRecentlyWatchedWindow);

  Future<void> _randomEpisode() async {
    final controller = _controller;
    if (controller == null || _picking) return;
    final pool = controller.activeShows;
    if (pool.isEmpty) {
      showAppSnackBar(context, controller.shows.isEmpty ? t.comfort.emptyTitle : t.comfort.allPaused);
      return;
    }
    setState(() => _picking = true);
    try {
      while (mounted) {
        final pick = await pickComfortEpisode<CatalogItem, MediaItem>(
          shows: pool,
          episodesFor: _localEpisodes,
          isRecentlyWatched: _isRecentlyWatched,
        );
        if (!mounted) return;
        if (pick == null) {
          showAppSnackBar(context, t.comfort.nothingToPlay);
          return;
        }
        final choice = SettingsService.instance.read(SettingsService.comfortPlayImmediately)
            ? _PickChoice.play
            : await _showPick(pick);
        if (!mounted) return;
        if (choice == _PickChoice.play) {
          await navigateToVideoPlayer(context, metadata: pick.episode);
          return;
        }
        if (choice != _PickChoice.again) return;
      }
    } catch (e) {
      appLogger.w('Comfort: random episode failed', error: e);
      if (mounted) showErrorSnackBar(context, t.comfort.nothingToPlay);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<_PickChoice?> _showPick(ComfortPick<CatalogItem, MediaItem> pick) {
    final episode = pick.episode;
    final season = episode.parentIndex;
    final number = episode.index;
    final label = season != null && number != null ? t.comfort.episodeLabel(season: season, episode: number) : null;
    return showScopedDialog<_PickChoice>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: Text(episode.grandparentTitle ?? pick.show.title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [?label, ?episode.title].join(' · '),
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (episode.summary case final summary? when summary.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(summary, maxLines: 5, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          actions: [
            DialogActionButton(
              onPressed: () => Navigator.pop(dialogContext, _PickChoice.again),
              label: t.comfort.pickAgain,
            ),
            DialogActionButton(
              autofocus: true,
              isPrimary: true,
              onPressed: () => Navigator.pop(dialogContext, _PickChoice.play),
              label: t.comfort.play,
            ),
          ],
        );
      },
    );
  }

  Future<void> _openConfigure() async {
    final controller = _controller;
    final source = _traktSource;
    if (controller == null || source == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComfortConfigureScreen(controller: controller, source: source),
      ),
    );
    _episodesByShow.clear();
  }

  // --- Layout ---------------------------------------------------------------

  List<MediaHub> get _hubs {
    final controller = _controller;
    if (controller == null) return const [];
    MediaHub hub(String id, String title, List<CatalogItem> items) => MediaHub(
      id: 'comfort:$id',
      identifier: 'comfort.$id',
      title: title,
      type: 'show',
      items: [for (final item in items) item.toMediaItem()],
      size: items.length,
    );
    final carryOn = comfortCarryOn(_discover?.onDeck ?? const [], {
      for (final show in controller.shows) normalizeShowTitle(show.title),
    });
    return [
      if (carryOn.isNotEmpty)
        MediaHub(
          id: _carryOnHubId,
          identifier: 'comfort.carryon',
          title: t.comfort.carryOn,
          type: 'mixed',
          items: carryOn,
          size: carryOn.length,
        ),
      if (controller.activeShows.isNotEmpty) hub('mix', t.comfort.inTheMix, controller.activeShows),
      if (controller.pausedShows.isNotEmpty) hub('paused', t.comfort.paused, controller.pausedShows),
    ];
  }

  static IconData _iconFor(MediaHub hub) => switch (hub.identifier) {
    'comfort.paused' => Symbols.pause_circle_rounded,
    'comfort.carryon' => Symbols.play_circle_rounded,
    _ => Symbols.weekend_rounded,
  };

  void _navigateToSidebar() => MainScreenFocusScope.focusSidebarOf(context);

  Widget? _buildStateMessage() {
    final controller = _controller;
    if (controller == null || (!controller.canEditList && controller.isLoaded && controller.shows.isEmpty)) {
      return EmptyStateWidget(
        message: t.comfort.notConnectedTitle,
        subtitle: t.comfort.notConnectedMessage,
        icon: Symbols.weekend_rounded,
        // Comfort is always in the phone's bottom bar, so offer the way in.
        actionLabel: t.comfort.connectTrakt,
        onAction: () =>
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TraktSettingsScreen())),
      );
    }
    if (!controller.isLoaded && controller.error == null) return const Center(child: CircularProgressIndicator());
    if (!controller.isLoaded) {
      return ErrorStateWidget(
        message: t.comfort.loadFailed,
        icon: Symbols.error_outline_rounded,
        onRetry: () => unawaited(_load()),
      );
    }
    if (controller.shows.isEmpty) {
      return EmptyStateWidget(
        message: t.comfort.emptyTitle,
        subtitle: t.comfort.emptyMessage,
        icon: Symbols.weekend_rounded,
      );
    }
    return null;
  }

  Widget _labelled(IconData icon, String label, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      AppIcon(icon, fill: 1, size: 22, color: color),
      const SizedBox(width: 8),
      Text(
        label,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    ],
  );

  /// Phone: Random episode as an icon, Configure and Refresh in the side
  /// drawer, beside the shared Search / remote / avatar set.
  List<FocusableAction> _phoneActions(Color color) => [
    FocusableAction(
      debugLabel: 'ComfortRandomEpisode',
      icon: _picking ? Symbols.hourglass_top_rounded : Symbols.casino_rounded,
      iconColor: color,
      tooltip: t.comfort.randomEpisode,
      onPressed: _controller == null || _picking ? null : () => unawaited(_randomEpisode()),
    ),
    ...phoneTabActions(
      context,
      color: color,
      onRefresh: manualRefresh,
      extras: [
        if (_traktSource != null) (Symbols.tune_rounded, t.comfort.configure, () => unawaited(_openConfigure())),
      ],
    ),
  ];

  List<FocusableAction> _actions(Color color) => [
    FocusableAction(
      debugLabel: 'ComfortRandomEpisode',
      onPressed: _controller == null || _picking ? null : () => unawaited(_randomEpisode()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: _picking
            ? _labelled(Symbols.hourglass_top_rounded, t.comfort.picking, color)
            : _labelled(Symbols.casino_rounded, t.comfort.randomEpisode, color),
      ),
    ),
    FocusableAction(
      debugLabel: 'ComfortConfigure',
      onPressed: _traktSource == null ? null : () => unawaited(_openConfigure()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: _labelled(Symbols.tune_rounded, t.comfort.configure, color),
      ),
    ),
    FocusableAction(
      icon: Symbols.refresh_rounded,
      iconColor: color,
      tooltip: t.common.refresh,
      onPressed: manualRefresh,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final hubs = _hubs;
    if (PlatformDetector.isTV()) {
      return SettingsBuilder(
        prefs: const [SettingsService.hideSpoilers, SettingsService.libraryDensity, SettingsService.episodePosterMode],
        builder: (context) => _buildTvContent(hubs),
      );
    }
    return _buildDesktopContent(hubs);
  }

  /// Comfort shows can be added to Home as a row.
  List<MediaMenuExtraEntry> _homeRowMenuEntriesFor(MediaHub hub) => hub.id == _carryOnHubId
      ? homeRowMenuEntries(context, (id: HomeRowIds.comfortCarryOn, title: t.comfort.carryOn, sources: const []))
      : homeRowMenuEntries(context, (id: HomeRowIds.comfort, title: t.homeRows.comfortRow, sources: const []));

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
                onFocusedItemChanged: _spotlight.select,
                onNavigateUp: _actionBarKey.currentState?.requestFocusOnFirst,
                onNavigateToSidebar: _navigateToSidebar,
                onBack: _navigateToSidebar,
                tallPosterScale: TvBrowseRailLayout.compactTallPosterScale,
                widePosterScale: TvBrowseRailLayout.compactEpisodeThumbnailScale,
                expandedTop: TvSpotlightScaffold.condensedRailTopFor(MediaQuery.sizeOf(context)),
                onExpandedChanged: (expanded) => _tvRowsExpanded.value = expanded,
                rowMenuEntriesForHub: _homeRowMenuEntriesFor,
                // Part-watched episodes resume where they stopped.
                usesContinueWatchingAction: (hub) => hub.id == _carryOnHubId,
                showTimeLeftForHub: (hub) => hub.id == _carryOnHubId,
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
                    spacing: 8,
                    actions: _actions(foregroundColor),
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
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: ForkMotion.refreshing(_load),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            DesktopSliverAppBar(
              title: Text(t.navigation.comfort),
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
                  actions: PlatformDetector.isMobile(context)
                      ? _phoneActions(Theme.of(context).colorScheme.onSurface)
                      : _actions(Theme.of(context).colorScheme.onSurface),
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
