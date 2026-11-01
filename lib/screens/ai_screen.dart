import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/focusable_action_bar.dart';
import '../focus/locked_hub_controller.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../mixins/refreshable.dart';
import '../mixins/tab_visibility_aware.dart';
import '../navigation/main_screen_scope.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/multi_server_provider.dart';
import '../services/ai/ai_agent.dart';
import '../services/ai/ai_history.dart';
import '../services/ai/ai_key_store.dart';
import '../services/ai/claude_client.dart';
import '../services/catalog/home_pins.dart';
import '../services/catalog/trakt_catalog_source.dart';
import '../services/library_index/library_index.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../widgets/home_row_actions.dart';
import '../widgets/hub_section.dart';
import '../widgets/media_context_menu.dart' show MediaMenuExtraEntry, RowMenuEntries;
import '../widgets/side_navigation_rail.dart';
import '../widgets/toolbar_scrim.dart';
import '../widgets/tv_browse_rail.dart';
import '../widgets/tv_spotlight_scaffold.dart';
import 'libraries/state_messages.dart';
import 'settings/ai_settings_screen.dart';

/// The AI helper tab: a hello with "Tonight" picks on opening, then any
/// request typed with "Ask", each answer a row of playable cards. Every
/// answer is saved ([AiHistory]): the newest at the top, older ones below
/// with "Load more". Follow-ups remember the earlier requests in this visit.
class AiScreen extends StatefulWidget {
  const AiScreen({super.key});

  @override
  State<AiScreen> createState() => AiScreenState();
}

class AiScreenState extends State<AiScreen> with ManualRefreshable, FullRefreshable, TabVisibilityAware, FocusableTab {
  /// "Tonight" picks are made with Haiku and reused for this long.
  static const Duration _tonightFresh = Duration(hours: 4);
  static AiHistoryEntry? _tonightCache;
  static DateTime? _tonightAt;

  /// Saved rows shown at first, and added per "Load more".
  static const int _pageSize = 10;

  AiHistoryEntry? _tonightRow;

  /// Saved answers loaded so far, newest first.
  final List<AiHistoryEntry> _saved = [];
  int _savedTotal = 0;
  bool _historyLoaded = false;

  /// Answers asked on this visit sit above Tonight; older ones below it.
  int _askedThisVisit = 0;
  final List<({String request, AiAnswer answer})> _conversation = [];
  bool _busy = false;
  bool? _hasKey;
  String? _status;
  final ValueNotifier<String?> _focusedReason = ValueNotifier(null);

  final _actionBarKey = GlobalKey<FocusableActionBarState>();
  final _tvBrowseRailKey = GlobalKey<TvBrowseRailState>();
  final _hubFocusMemory = HubFocusMemory();
  final TvSpotlightController _spotlight = TvSpotlightController();
  final ValueNotifier<bool> _tvRowsExpanded = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _spotlight.dispose();
    _tvRowsExpanded.dispose();
    _focusedReason.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!_historyLoaded) await _loadHistory();
    final key = await AiKeyStore.read();
    if (!mounted) return;
    setState(() => _hasKey = key != null);
    if (key != null) await _tonight();
  }

  Future<void> _loadHistory() async {
    try {
      final total = await AiHistory.count();
      final page = await AiHistory.page(limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _historyLoaded = true;
        _savedTotal = total;
        _saved
          ..clear()
          ..addAll(page);
      });
    } catch (e) {
      appLogger.w('AI tab: loading saved answers failed', error: e);
    }
  }

  Future<void> _loadMore() async {
    final more = await AiHistory.page(offset: _saved.length, limit: _pageSize);
    if (!mounted) return;
    setState(() => _saved.addAll(more.where((e) => !_saved.any((s) => s.id == e.id))));
  }

  AiAgent _agent(ClaudeModel model) {
    final trakt = context.read<CatalogSourcesProvider?>()?.connectedSources.whereType<TraktCatalogSource>().firstOrNull;
    return AiAgent(index: LibraryIndex.instance, trakt: trakt?.client, model: model);
  }

  Future<void> _tonight({bool refresh = false}) async {
    final at = _tonightAt;
    final cached = _tonightCache;
    if (!refresh && cached != null && at != null && DateTime.now().difference(at) < _tonightFresh) {
      setState(() => _tonightRow = cached);
      return;
    }
    final result = await _run(AiAgent.tonightRequest, ClaudeModel.haiku, status: t.aiTab.preparingTonight);
    if (result == null || !mounted) return;
    _tonightCache = result.entry;
    _tonightAt = DateTime.now();
    setState(() => _tonightRow = result.entry);
  }

  Future<void> _ask() async {
    final request = await showTextInputDialog(
      context,
      title: _conversation.isEmpty ? t.aiTab.askTitle : t.aiTab.followUpTitle,
      labelText: t.ai.tryRequestLabel,
      hintText: t.aiTab.askHint,
      confirmText: t.ai.ask,
    );
    final text = request?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    final result = await _run(text, ClaudeModel.sonnet, status: t.aiTab.thinking(request: text), withHistory: true);
    if (result == null || !mounted) return;
    _conversation.add((request: text, answer: result.answer));
    try {
      await AiHistory.add(result.entry);
    } catch (e) {
      appLogger.w('AI tab: saving the answer failed', error: e);
    }
    if (!mounted) return;
    setState(() {
      _saved.insert(0, result.entry);
      _savedTotal++;
      _askedThisVisit++;
    });
    // New answers appear at the top; put focus on them.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tvBrowseRailKey.currentState?.requestFocus());
  }

  /// Forget the follow-up context; saved rows stay.
  void _newConversation() => setState(_conversation.clear);

  HomeRowEntry _homeRow(AiHistoryEntry entry) => (id: HomeRowIds.ai(entry.id), title: entry.request, sources: const []);

  /// Re-run a saved request (one Sonnet call) and replace its picks.
  Future<void> _refreshRow(AiHistoryEntry entry) async {
    final result = await _run(
      entry.request,
      ClaudeModel.sonnet,
      status: t.aiTab.refreshing(request: entry.request),
      id: entry.id,
    );
    if (result == null || !mounted) return;
    await AiHistory.replace(result.entry);
    if (!mounted) return;
    setState(() {
      final i = _saved.indexWhere((e) => e.id == entry.id);
      if (i >= 0) _saved[i] = result.entry;
    });
  }

  Future<void> _deleteRow(AiHistoryEntry entry) async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.aiTab.deleteRowTitle(request: entry.request),
      message: t.aiTab.deleteRowMessage,
      confirmText: t.common.delete,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    final homeId = HomeRowIds.ai(entry.id);
    if (HomePinsController.instance.contains(homeId)) await HomePinsController.instance.remove([homeId]);
    await AiHistory.remove(entry.id);
    if (!mounted) return;
    final i = _saved.indexWhere((e) => e.id == entry.id);
    setState(() {
      if (i >= 0) {
        _saved.removeAt(i);
        _savedTotal--;
        if (i < _askedThisVisit) _askedThisVisit--;
      }
    });
    showSuccessSnackBar(context, t.aiTab.deleted);
  }

  List<MediaMenuExtraEntry> _rowMenuEntries(MediaHub hub) {
    final entry = _entryForHub(hub);
    if (entry == null || entry.request == AiAgent.tonightRequest) return const [];
    return [
      ...homeRowMenuEntries(context, _homeRow(entry)),
      MediaMenuExtraEntry(
        icon: Symbols.refresh_rounded,
        label: t.aiTab.refreshRow,
        onSelected: () => unawaited(_refreshRow(entry)),
      ),
      MediaMenuExtraEntry(
        icon: Symbols.delete_rounded,
        label: t.aiTab.deleteRow,
        onSelected: () => unawaited(_deleteRow(entry)),
      ),
    ];
  }

  /// Ask the helper and turn its picks into playable items, as an entry
  /// with [id] (a new one when not given).
  Future<({AiAnswer answer, AiHistoryEntry entry})?> _run(
    String request,
    ClaudeModel model, {
    required String status,
    bool withHistory = false,
    String? id,
  }) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _status = status;
    });
    final agent = _agent(model);
    try {
      final answer = await agent.ask(request, previous: withHistory ? List.of(_conversation) : const []);
      if (!mounted) return null;
      if (answer.error != null) {
        setState(() => _status = answer.error);
        return null;
      }
      final servers = context.read<MultiServerProvider>();
      final fetched = await Future.wait([
        for (final pick in answer.picks)
          () async {
            try {
              final item = await servers
                  .getClientForServer(ServerId(pick.title.serverId))
                  ?.fetchItem(pick.title.ratingKey);
              return item == null ? null : (item: item, reason: pick.reason);
            } catch (e) {
              appLogger.d('AI tab: fetching ${pick.title.title} failed', error: e);
              return null;
            }
          }(),
      ]);
      final picks = [...fetched.nonNulls];
      setState(() => _status = picks.isEmpty ? (answer.intro ?? answer.text) : null);
      if (picks.isEmpty) return null;
      return (
        answer: answer,
        entry: AiHistoryEntry(
          id: id ?? AiHistory.newId(),
          request: request,
          intro: answer.intro,
          createdAt: DateTime.now(),
          items: [for (final p in picks) p.item],
          reasons: {for (final p in picks) p.item.globalKey: p.reason},
        ),
      );
    } finally {
      agent.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Rows in order: this visit's answers, Tonight, then older saved ones.
  List<AiHistoryEntry> get _rows => [
    ..._saved.take(_askedThisVisit),
    ?_tonightRow,
    ..._saved.skip(_askedThisVisit),
  ];

  static String _hubId(AiHistoryEntry entry) => 'aitab:${entry.id}';

  AiHistoryEntry? _entryForHub(MediaHub hub) => _rows.where((e) => _hubId(e) == hub.id).firstOrNull;

  List<MediaHub> get _hubs => [
    for (final row in _rows)
      MediaHub(
        id: _hubId(row),
        identifier: 'ai.answer',
        title: row.request == AiAgent.tonightRequest ? t.aiTab.tonight : row.request,
        type: 'mixed',
        items: row.items,
        size: row.items.length,
      ),
  ];

  void _onFocused(MediaHub hub, MediaItem item) {
    _spotlight.select(item);
    _focusedReason.value = _entryForHub(hub)?.reasons[item.globalKey];
  }

  String? get _headline => _rows.firstOrNull?.intro;

  bool get _hasMore => _saved.length < _savedTotal;

  @override
  void manualRefresh() => unawaited(_tonight(refresh: true));

  @override
  void fullRefresh() => unawaited(_tonight(refresh: true));

  @override
  void onTabShown() {
    if (_hasKey == null) return;
    unawaited(_start());
  }

  @override
  void onTabHidden() {}

  @override
  void focusActiveTabIfReady() {
    if (_rows.isNotEmpty) {
      _tvBrowseRailKey.currentState?.requestFocus();
    } else {
      _actionBarKey.currentState?.requestFocusOnFirst();
    }
  }

  void _navigateToSidebar() => MainScreenFocusScope.focusSidebarOf(context);

  List<FocusableAction> _actions(Color color) => [
    FocusableAction(
      debugLabel: 'AiAsk',
      autofocus: _rows.isEmpty,
      onPressed: _busy || _hasKey != true ? null : () => unawaited(_ask()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.auto_awesome_rounded, size: 22, color: color),
            const SizedBox(width: 8),
            Text(
              _conversation.isEmpty ? t.aiTab.ask : t.aiTab.followUp,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ),
    if (_conversation.isNotEmpty)
      FocusableAction(
        icon: Symbols.add_comment_rounded,
        iconColor: color,
        tooltip: t.aiTab.newConversation,
        onPressed: _busy ? null : _newConversation,
      ),
    FocusableAction(
      icon: Symbols.refresh_rounded,
      iconColor: color,
      tooltip: t.aiTab.refreshTonight,
      onPressed: _busy || _hasKey != true ? null : () => unawaited(_tonight(refresh: true)),
    ),
    if (_hasMore)
      FocusableAction(
        icon: Symbols.expand_more_rounded,
        iconColor: color,
        tooltip: t.aiTab.loadMore,
        onPressed: () => unawaited(_loadMore()),
      ),
  ];

  Widget? _message() {
    if (_hasKey == false) {
      return Center(
        child: EmptyStateWidget(
          message: t.aiTab.noKeyTitle,
          subtitle: t.aiTab.noKeyMessage,
          icon: Symbols.key_rounded,
          actionLabel: t.ai.settingsTitle,
          onAction: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const AiSettingsScreen())).then((_) => _start()),
        ),
      );
    }
    if (_rows.isEmpty) {
      return Center(
        child: _busy
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_status ?? '', style: Theme.of(context).textTheme.titleMedium),
                ],
              )
            : EmptyStateWidget(
                message: t.aiTab.emptyTitle,
                subtitle: _status ?? t.aiTab.emptyMessage,
                icon: Symbols.auto_awesome_rounded,
              ),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final hubs = _hubs;
    final message = _message();
    final color = Theme.of(context).colorScheme.onSurface;
    if (!PlatformDetector.isTV()) {
      return FocusedScrollScaffold(
        title: Text(t.navigation.ai),
        actions: [FocusableActionBar(key: _actionBarKey, actions: _actions(color))],
        slivers: [
          if (message != null)
            SliverFillRemaining(child: message)
          else
            for (final hub in hubs)
              SliverToBoxAdapter(
                child: RowMenuEntries(
                  entries: _rowMenuEntries(hub),
                  child: HubSection(hub: hub, focusMemory: _hubFocusMemory, icon: Symbols.auto_awesome_rounded),
                ),
              ),
          if (message == null && _hasMore)
            SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextButton.icon(
                    onPressed: () => unawaited(_loadMore()),
                    icon: const Icon(Symbols.expand_more_rounded),
                    label: Text(t.aiTab.loadMore),
                  ),
                ),
              ),
            ),
        ],
      );
    }
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
                iconForHub: (_, _) => Symbols.auto_awesome_rounded,
                rowMenuEntriesForHub: _rowMenuEntries,
                onFocusedHubItemChanged: _onFocused,
                onNavigateUp: _actionBarKey.currentState?.requestFocusOnFirst,
                onNavigateToSidebar: _navigateToSidebar,
                onBack: _navigateToSidebar,
                tallPosterScale: TvBrowseRailLayout.compactTallPosterScale,
                widePosterScale: TvBrowseRailLayout.compactEpisodeThumbnailScale,
                expandedTop: TvSpotlightScaffold.condensedRailTopFor(MediaQuery.sizeOf(context)),
                onExpandedChanged: (expanded) => _tvRowsExpanded.value = expanded,
              ),
            ),
          TvToolbarOverlay(
            child: ToolbarScrim(
              child: Row(
                children: [
                  // The focused pick's reason (or the helper's intro).
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: SideNavigationRailState.tvCollapsedWidth + 24, right: 16),
                      child: ValueListenableBuilder<String?>(
                        valueListenable: _focusedReason,
                        builder: (context, reason, _) {
                          final text = _busy ? _status : (reason ?? _headline);
                          if (text == null) return const SizedBox.shrink();
                          return Row(
                            children: [
                              if (_busy)
                                const Padding(
                                  padding: EdgeInsets.only(right: 12),
                                  child: SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                )
                              else
                                Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: Icon(Symbols.auto_awesome_rounded, size: 20, color: color),
                                ),
                              Expanded(
                                child: Text(
                                  text,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  FocusableActionBar(
                    key: _actionBarKey,
                    onNavigateLeft: _navigateToSidebar,
                    onNavigateDown: _tvBrowseRailKey.currentState?.requestFocus,
                    onBack: _navigateToSidebar,
                    spacing: 8,
                    actions: _actions(color),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
