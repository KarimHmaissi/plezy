import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_action_bar.dart';
import '../focus/locked_hub_controller.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_hub.dart';
import '../models/trakt/trakt_user_list.dart';
import '../services/catalog/trakt_lists_catalog_source.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/app_icon.dart';
import '../widgets/focusable_list_tile.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../widgets/hub_section.dart';
import '../widgets/loading_indicator_box.dart';
import '../widgets/toolbar_scrim.dart';
import '../widgets/tv_browse_rail.dart';
import '../widgets/tv_spotlight_scaffold.dart';
import 'home_rows_screen.dart';
import 'libraries/state_messages.dart';

/// Trending and popular public Trakt lists. Opening one shows its items with
/// a Like toggle; liked lists appear as rows under Explore ▸ Trakt Lists.
class TraktDiscoverListsScreen extends StatefulWidget {
  final TraktListsCatalogSource source;

  const TraktDiscoverListsScreen({super.key, required this.source});

  @override
  State<TraktDiscoverListsScreen> createState() => _TraktDiscoverListsScreenState();
}

class _TraktDiscoverListsScreenState extends State<TraktDiscoverListsScreen> {
  List<TraktUserList>? _trending;
  List<TraktUserList>? _popular;
  Set<int> _liked = {};
  Object? _error;

  /// Whether a like changed while browsing, so Explore can reload its rows.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final client = widget.source.trakt.client;
    try {
      final results = await Future.wait([
        client.getPublicLists(trending: true),
        client.getPublicLists(trending: false),
        client.getLikedLists(),
      ]);
      if (!mounted) return;
      setState(() {
        _trending = results[0];
        _popular = results[1];
        _liked = {for (final list in results[2]) list.traktId};
      });
    } catch (e) {
      appLogger.w('Trakt Lists: discover load failed', error: e);
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(TraktUserList list) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            TraktListScreen(source: widget.source, list: list, initiallyLiked: _liked.contains(list.traktId)),
      ),
    );
    if (changed == true) {
      _changed = true;
      unawaited(_load());
    }
  }

  Widget _tile(TraktUserList list, {required bool autofocus}) => FocusableListTile(
    autofocus: autofocus,
    leading: AppIcon(
      _liked.contains(list.traktId) ? Symbols.favorite_rounded : Symbols.format_list_bulleted_rounded,
      fill: 1,
    ),
    title: Text(list.name),
    subtitle: Text(
      t.explore.traktLists.listByUser(user: list.userSlug ?? '?', count: list.itemCount ?? 0),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    onTap: () => unawaited(_open(list)),
  );

  @override
  Widget build(BuildContext context) {
    final trending = _trending;
    final popular = _popular;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: FocusedScrollScaffold(
        title: Text(t.explore.traktLists.discoverLists),
        slivers: [
          if (_error != null && trending == null)
            SliverFillRemaining(
              child: ErrorStateWidget(
                message: _error.toString(),
                icon: Symbols.error_outline_rounded,
                onRetry: () => unawaited(_load()),
              ),
            )
          else if (trending == null || popular == null)
            LoadingIndicatorBox.sliver
          else
            SliverList.list(
              children: [
                ListTile(
                  title: Text(t.explore.traktLists.trendingLists, style: Theme.of(context).textTheme.titleMedium),
                ),
                for (final (i, list) in trending.indexed) _tile(list, autofocus: i == 0),
                ListTile(
                  title: Text(t.explore.traktLists.popularLists, style: Theme.of(context).textTheme.titleMedium),
                ),
                for (final list in popular) _tile(list, autofocus: false),
              ],
            ),
        ],
      ),
    );
  }
}

/// One Trakt list's items as a browse row, with a Like toggle. Pops `true`
/// when the like changed.
class TraktListScreen extends StatefulWidget {
  final TraktListsCatalogSource source;
  final TraktUserList list;
  final bool initiallyLiked;

  const TraktListScreen({super.key, required this.source, required this.list, required this.initiallyLiked});

  @override
  State<TraktListScreen> createState() => _TraktListScreenState();
}

class _TraktListScreenState extends State<TraktListScreen> {
  static const int _limit = 100;

  MediaHub? _hub;
  Object? _error;
  late bool _liked = widget.initiallyLiked;
  bool _changed = false;
  bool _busy = false;

  final _actionBarKey = GlobalKey<FocusableActionBarState>();
  final _railKey = GlobalKey<TvBrowseRailState>();
  final _focusMemory = HubFocusMemory();
  final TvSpotlightController _spotlight = TvSpotlightController();

  String get _hubId => TraktListsCatalogSource.listHubId(widget.list);

  @override
  void initState() {
    super.initState();
    widget.source.pins.addListener(_onPinsChanged);
    unawaited(widget.source.pins.ensureLoaded());
    unawaited(_load());
  }

  void _onPinsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.source.pins.removeListener(_onPinsChanged);
    _spotlight.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final page = await widget.source.fetchHub(_hubId, limit: _limit);
      if (!mounted) return;
      setState(() {
        _hub = MediaHub(
          id: 'trakt_list:${widget.list.traktId}',
          title: widget.list.name,
          type: 'mixed',
          items: [for (final item in page.items) item.toMediaItem()],
          size: page.totalResults ?? page.items.length,
        );
      });
    } catch (e) {
      appLogger.w('Trakt Lists: list load failed', error: e);
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _toggleLike() async {
    final user = widget.list.userSlug;
    if (user == null || _busy) return;
    setState(() => _busy = true);
    try {
      final client = widget.source.trakt.client;
      _liked ? await client.unlikeList(user, widget.list.traktId) : await client.likeList(user, widget.list.traktId);
      if (!mounted) return;
      setState(() {
        _liked = !_liked;
        _changed = !_changed;
      });
    } catch (e) {
      appLogger.w('Trakt Lists: like toggle failed', error: e);
      if (mounted) showErrorSnackBar(context, t.explore.traktLists.likeFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePin() async {
    final pins = widget.source.pins;
    final pinned = !pins.isPinned(_hubId);
    try {
      await pins.setPinned(_hubId, widget.list.name, pinned);
      if (!mounted) return;
      showSuccessSnackBar(
        context,
        pinned ? t.homeRows.pinned(title: widget.list.name) : t.homeRows.unpinned(title: widget.list.name),
      );
    } catch (e) {
      appLogger.w('Trakt Lists: pin toggle failed', error: e);
      if (mounted) showErrorSnackBar(context, homeRowsSaveError(e));
    }
  }

  FocusableAction _pinAction(Color color) {
    final pinned = widget.source.pins.isPinned(_hubId);
    return FocusableAction(
      debugLabel: 'TraktListPin',
      onPressed: () => unawaited(_togglePin()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(Symbols.keep_rounded, fill: pinned ? 1 : 0, size: 22, color: color),
            const SizedBox(width: 8),
            Text(
              pinned ? t.explore.traktLists.pinned : t.explore.traktLists.pin,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  FocusableAction _likeAction(Color color) => FocusableAction(
    debugLabel: 'TraktListLike',
    autofocus: true,
    onPressed: _busy ? null : () => unawaited(_toggleLike()),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(_liked ? Symbols.favorite_rounded : Symbols.favorite_border_rounded, fill: 1, size: 22, color: color),
          const SizedBox(width: 8),
          Text(
            _liked ? t.explore.traktLists.liked : t.explore.traktLists.like,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hub = _hub;
    final color = Theme.of(context).colorScheme.onSurface;
    final Widget body;
    if (hub == null) {
      body = _error == null
          ? const Center(child: CircularProgressIndicator())
          : ErrorStateWidget(message: _error.toString(), icon: Symbols.error_outline_rounded, onRetry: _load);
    } else if (PlatformDetector.isTV()) {
      body = TvSpotlightScaffold(
        hubs: [hub],
        spotlightListenable: _spotlight,
        resolveSpotlight: () => _spotlight.resolve([hub]),
        resolveClient: (spotlight) => context.tryGetMediaClientForServer(serverIdOrNull(spotlight?.serverId)),
        foreground: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: TvBrowseRail(
                key: _railKey,
                hubs: [hub],
                focusMemory: _focusMemory,
                iconForHub: (_, _) => Symbols.format_list_bulleted_rounded,
                onFocusedItemChanged: _spotlight.select,
                onNavigateUp: _actionBarKey.currentState?.requestFocusOnFirst,
                onBack: () => Navigator.of(context).maybePop(),
                tallPosterScale: TvBrowseRailLayout.compactTallPosterScale,
                widePosterScale: TvBrowseRailLayout.compactEpisodeThumbnailScale,
              ),
            ),
            TvToolbarOverlay(
              child: ToolbarScrim(
                child: Row(
                  children: [
                    const Spacer(),
                    FocusableActionBar(
                      key: _actionBarKey,
                      onNavigateDown: _railKey.currentState?.requestFocus,
                      onBack: () => Navigator.of(context).maybePop(),
                      actions: [_likeAction(color), _pinAction(color)],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      body = FocusedScrollScaffold(
        title: Text(widget.list.name),
        actions: [
          FocusableActionBar(key: _actionBarKey, actions: [_likeAction(color), _pinAction(color)]),
        ],
        slivers: [
          SliverToBoxAdapter(
            child: HubSection(hub: hub, focusMemory: _focusMemory, icon: Symbols.list_rounded),
          ),
        ],
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: PlatformDetector.isTV() ? Scaffold(body: body) : body,
    );
  }
}
