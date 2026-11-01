import 'dart:async';

import 'package:flutter/foundation.dart';
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
import '../providers/companion_remote_provider.dart';
import '../providers/multi_server_provider.dart';
import '../services/ai/ai_remote_asks.dart';
import '../media/media_kind.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/video_player_navigation.dart';
import '../models/companion_remote/remote_command.dart';
import '../services/companion_remote/mirror_sync.dart';
import '../theme/fork_motion.dart';
import '../services/customisation/customisation_store.dart';
import '../services/ai/ai_activity.dart';
import '../services/ai/ai_agent.dart';
import '../services/ai/ai_history.dart';
import 'ai_composer.dart';
import 'ai_pick_open.dart';
import '../services/settings_service.dart';
import '../services/ai/ai_home_refresher.dart';
import '../services/ai/ai_more_like_this.dart';
import '../services/ai/ai_rows.dart';
import '../services/ai/ai_key_store.dart';
import '../services/ai/claude_client.dart';
import '../services/catalog/home_pins.dart';
import '../services/catalog/trakt_catalog_source.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../widgets/home_row_actions.dart';
import '../widgets/hub_section.dart';
import '../widgets/media_context_menu.dart' show ItemMenuEntries, MediaMenuExtraEntry, RowMenuEntries;
import '../widgets/side_navigation_rail.dart';
import '../widgets/toolbar_scrim.dart';
import '../widgets/tv_browse_rail.dart';
import '../widgets/tv_spotlight_scaffold.dart';
import 'companion_remote/remote_ai_screen.dart';
import 'libraries/state_messages.dart';
import 'settings/ai_settings_screen.dart';

/// A request running in the background (or failed, waiting for Retry);
/// [replaceId] is set when it refreshes a saved row.
class _PendingAsk {
  _PendingAsk(
    this.request, {
    this.replaceId,
    this.previous = const [],
    String? label,
    this.useTitle = false,
    this.extend,
  }) : label = label ?? request;

  final String request;

  /// What the chip shows ("more like Severance" rather than the prompt).
  final String label;
  final String? replaceId;
  final List<({String request, AiAnswer answer})> previous;

  /// Name the row with the AI's title instead of the request.
  final bool useTitle;

  /// Find more: new picks go in front of this answer's, which are kept.
  final AiHistoryEntry? extend;
  String? error;
}

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

  /// Requests running in the background, shown as chips in the toolbar;
  /// browsing carries on meanwhile.
  final List<_PendingAsk> _pending = [];
  bool _visible = true;
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
    AiMoreLikeThis.requests.addListener(_takeMoreLikeThis);
    AiHistory.replaced.addListener(_onReplaced);
    AiRemoteAsks.landed.addListener(_onLanded);
    Customisation.changed.addListener(_onDataChanged);
    RemoteAiSession.instance.addListener(_onRemoteAsks);
    unawaited(_start());
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeMoreLikeThis());
  }

  /// A saved answer got new picks elsewhere (Home's auto-refresh): show them.
  Future<void> _onReplaced() async {
    final id = AiHistory.replaced.value;
    if (id == null || !_saved.any((e) => e.id == id)) return;
    final fresh = await AiHistory.get(id);
    if (!mounted || fresh == null) return;
    setState(() {
      final i = _saved.indexWhere((e) => e.id == id);
      if (i >= 0) _saved[i] = fresh;
    });
  }

  /// A connected phone's request was answered: add it as the top row.
  Future<void> _onLanded() async {
    final id = AiRemoteAsks.landed.value;
    if (id == null || _saved.any((e) => e.id == id)) return;
    final fresh = await AiHistory.get(id);
    if (!mounted || fresh == null || _saved.any((e) => e.id == id)) return;
    setState(() {
      _saved.insert(0, fresh);
      _savedTotal++;
      _askedThisVisit++;
    });
    if (_visible) {
      showAppSnackBar(context, t.aiTab.ready(request: fresh.label));
    } else {
      AiActivity.unseen.value++;
    }
  }

  /// Start any "More like this" requests from long-press menus.
  void _takeMoreLikeThis() {
    if (!mounted) return;
    if (_thinClient) {
      final remote = context.read<CompanionRemoteProvider>();
      if (!(remote.isRemote && remote.isConnected)) return;
      for (final seed in AiMoreLikeThis.take()) {
        RemoteAiSession.instance.ask(remote, AiMoreLikeThis.prompt(seed));
      }
      return;
    }
    for (final seed in AiMoreLikeThis.take()) {
      unawaited(
        _runInBackground(
          _PendingAsk(AiMoreLikeThis.prompt(seed), label: t.aiTab.moreLike(title: seed.title), useTitle: true),
        ),
      );
    }
  }

  @override
  void dispose() {
    AiMoreLikeThis.requests.removeListener(_takeMoreLikeThis);
    AiHistory.replaced.removeListener(_onReplaced);
    AiRemoteAsks.landed.removeListener(_onLanded);
    Customisation.changed.removeListener(_onDataChanged);
    RemoteAiSession.instance.removeListener(_onRemoteAsks);
    _spotlight.dispose();
    _tvRowsExpanded.dispose();
    _focusedReason.dispose();
    super.dispose();
  }

  /// The saved answers changed elsewhere: a phone's edit applied here, or
  /// (on a phone) a new snapshot from the TV.
  void _onDataChanged() {
    if (!mounted) return;
    if (_thinClient) {
      setState(() => _hasKey = true);
      // Mirroring (or its connection) changed; the build picks the layout.
    }
    unawaited(_loadHistory());
  }

  void _onRemoteAsks() {
    if (mounted && _thinClient) setState(() {});
  }

  /// Phone, mirroring its TV: whether edits and requests can go to the TV.
  bool get _canEditMirror => MirrorClient.instance.canEdit;

  Future<void> _start() async {
    if (_thinClient) {
      // The TV runs requests; this shows its saved answers.
      _hasKey = true;
      if (Customisation.isMirror) await _loadHistory();
      return;
    }
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

  final _askKey = GlobalKey(debugLabel: 'AiAskButton');

  static Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _ask() async {
    if (_thinClient && !_canEditMirror) {
      // Not linked to the TV right now: say so and try to reconnect, rather
      // than a button that does nothing.
      final remote = context.read<CompanionRemoteProvider>();
      showAppSnackBar(
        context,
        t.cast.notConnected(name: MirrorClient.instance.hostName ?? t.companionRemote.unknownDevice),
      );
      final host = SettingsService.instance.read(SettingsService.companionRemoteAutoHost);
      if (host != null && !remote.isConnected) unawaited(remote.autoConnect(host));
      return;
    }
    final remote = _thinClient ? context.read<CompanionRemoteProvider>() : null;
    final previous = List.of(_conversation);
    _PendingAsk? lastFailed;
    await AiComposer.open(
      context,
      followUpOf: _conversation.isEmpty ? null : _conversation.last.request,
      recent: {
        for (final r in _rows)
          if (r.request != AiAgent.tonightRequest) r.request,
      }.take(5).toList(),
      posters: [for (final r in _rows.take(6)) ...r.items.take(8)],
      origin: _rectOf(_askKey),
      run: (text) async {
        if (remote != null) {
          final ask = await RemoteAiSession.instance.askAndWait(remote, text);
          final items = ask.answer?.items ?? const <MediaItem>[];
          return AiComposerOutcome(
            pick: items.isEmpty ? null : items.first,
            error: switch (ask.status) {
              'done' => null,
              'error' => (ask.error?.isNotEmpty ?? false) ? ask.error : t.aiTab.noPicks,
              _ => t.aiComposer.timedOut,
            },
          );
        }
        // A retry from the composer replaces its failed attempt's chip.
        final failed = lastFailed;
        if (failed != null && mounted) setState(() => _pending.remove(failed));
        final ask = _PendingAsk(text, previous: previous);
        await _runInBackground(ask);
        lastFailed = ask.error != null ? ask : null;
        if (ask.error != null) return AiComposerOutcome(error: ask.error);
        for (final r in _rows) {
          if (r.request == text) return AiComposerOutcome(pick: r.items.isEmpty ? null : r.items.first);
        }
        return const AiComposerOutcome();
      },
    );
  }

  /// Run [ask] while the user keeps browsing; the answer is saved and
  /// lands as the top row (or replaces the row it refreshes) without moving
  /// focus. Off the tab, the side nav shows a dot instead of a toast.
  Future<void> _runInBackground(_PendingAsk ask) async {
    setState(() {
      ask.error = null;
      if (!_pending.contains(ask)) _pending.add(ask);
    });
    AiActivity.running.value++;
    try {
      final extend = ask.extend;
      final result = await _fetch(
        ask.request,
        ClaudeModel.sonnet,
        previous: ask.previous,
        id: ask.replaceId,
        useTitle: ask.useTitle,
        keepTitle: extend?.title,
        sentRequest: extend == null ? null : findMoreRequest(extend),
        excludeKeys: {...?extend?.items.map((i) => i.globalKey)},
      );
      final found = result.entry;
      if (extend != null && found == null && result.answer.error == null) {
        // Nothing new that fits: say so rather than leaving a retry chip.
        if (!mounted) return;
        setState(() => _pending.remove(ask));
        showAppSnackBar(context, t.aiTab.noMoreMatches(request: extend.label));
        return;
      }
      if (found == null) {
        if (mounted) setState(() => ask.error = result.answer.error ?? result.answer.intro ?? t.aiTab.noPicks);
        return;
      }
      final entry = extend == null ? found : mergeFindMore(extend, found);
      if (ask.replaceId == null) {
        _conversation.add((request: ask.request, answer: result.answer));
        await AiHistory.add(entry);
      } else {
        await AiHistory.replace(entry);
      }
      if (!mounted) return;
      setState(() {
        _pending.remove(ask);
        if (ask.replaceId == null) {
          _saved.insert(0, entry);
          _savedTotal++;
          _askedThisVisit++;
        } else {
          final i = _saved.indexWhere((e) => e.id == entry.id);
          if (i >= 0) _saved[i] = entry;
        }
      });
      if (_visible) {
        showAppSnackBar(
          context,
          extend == null
              ? t.aiTab.ready(request: entry.label)
              : t.aiTab.addedMore(count: found.items.length, request: entry.label),
        );
      } else {
        AiActivity.unseen.value++;
      }
    } catch (e) {
      appLogger.w('AI tab: background request failed', error: e);
      if (mounted) setState(() => ask.error = '$e');
    } finally {
      AiActivity.running.value--;
    }
  }

  /// Forget the follow-up context (and failed requests); saved rows stay.
  void _newConversation() => setState(() {
    _conversation.clear();
    _pending.removeWhere((p) => p.error != null);
  });

  HomeRowEntry _homeRow(AiHistoryEntry entry) => (id: HomeRowIds.ai(entry.id), title: entry.label, sources: const []);

  /// Phone: Find more / Refresh run on the TV; the new picks come back with
  /// its next snapshot.
  Future<void> _remoteAction(String action, AiHistoryEntry entry) async {
    context.read<CompanionRemoteProvider>().sendCommand(
      RemoteCommandType.aiAction,
      data: {'action': action, 'id': entry.id},
    );
    showAppSnackBar(
      context,
      action == 'findMore' ? t.aiTab.findingMore(request: entry.label) : t.aiTab.thinking(request: entry.label),
    );
  }

  /// Re-run a saved request (one Sonnet call) and replace its picks.
  Future<void> _refreshRow(AiHistoryEntry entry) => _thinClient
      ? _remoteAction('refresh', entry)
      : _runInBackground(
          _PendingAsk(entry.request, replaceId: entry.id, label: entry.label, useTitle: entry.title != null),
        );

  /// Ask the same request again for titles not already in [entry]; the new
  /// batch goes in front and the old picks stay (see [mergeFindMore]).
  Future<void> _findMore(AiHistoryEntry entry) => _thinClient
      ? _remoteAction('findMore', entry)
      : _runInBackground(
          _PendingAsk(
            entry.request,
            replaceId: entry.id,
            label: t.aiTab.findingMore(request: entry.label),
            useTitle: entry.title != null,
            previous: List.of(_conversation),
            extend: entry,
          ),
        );

  Future<void> _deleteRow(AiHistoryEntry entry) async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.aiTab.deleteRowTitle(request: entry.label),
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
    if (_thinClient && !_canEditMirror) return const [];
    final homeRow = _homeRow(entry);
    final homeFull =
        !HomePinsController.instance.contains(homeRow.id) &&
        AiHomeRefresher.homeRowCount() >= AiHomeRefresher.maxHomeRows;
    return [
      for (final e in homeRowMenuEntries(context, homeRow))
        // At the cap, "Add to Home" explains instead of adding.
        homeFull && e.label == t.homeRows.addToHome
            ? MediaMenuExtraEntry(
                icon: e.icon,
                label: e.label,
                onSelected: () => showAppSnackBar(context, t.aiTab.homeFull),
              )
            : e,
      MediaMenuExtraEntry(
        icon: Symbols.playlist_add_rounded,
        label: t.aiTab.findMore,
        onSelected: () => unawaited(_findMore(entry)),
      ),
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

  /// Tonight picks, with the status line showing progress.
  Future<({AiAnswer answer, AiHistoryEntry entry})?> _run(
    String request,
    ClaudeModel model, {
    required String status,
  }) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _status = status;
    });
    try {
      final result = await _fetch(request, model);
      final entry = result.entry;
      if (!mounted) return null;
      setState(
        () => _status = entry == null ? (result.answer.error ?? result.answer.intro ?? result.answer.text) : null,
      );
      return entry == null ? null : (answer: result.answer, entry: entry);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ask the helper and turn its picks into playable items, as an entry
  /// with [id] (a new one when not given); no entry when nothing came back.
  Future<({AiAnswer answer, AiHistoryEntry? entry})> _fetch(
    String request,
    ClaudeModel model, {
    List<({String request, AiAnswer answer})> previous = const [],
    String? id,
    bool useTitle = false,
    String? keepTitle,
    String? sentRequest,
    Set<String> excludeKeys = const {},
  }) {
    final servers = context.read<MultiServerProvider>();
    final trakt = context.read<CatalogSourcesProvider?>()?.connectedSources.whereType<TraktCatalogSource>().firstOrNull;
    return buildAiRow(
      request: request,
      model: model,
      clientFor: servers.getClientForServer,
      trakt: trakt?.client,
      previous: previous,
      id: id,
      useTitle: useTitle,
      keepTitle: keepTitle,
      sentRequest: sentRequest,
      excludeKeys: excludeKeys,
    );
  }

  /// Rows in order: this visit's answers, Tonight, then older saved ones.
  List<AiHistoryEntry> get _rows => [..._saved.take(_askedThisVisit), ?_tonightRow, ..._saved.skip(_askedThisVisit)];

  static String _hubId(AiHistoryEntry entry) => 'aitab:${entry.id}';

  /// Load more card state per answer id; absent means ready.
  final Map<String, _MoreState> _more = {};

  /// The answer [hub] shows when it can take a Load more card.
  AiHistoryEntry? _loadMoreEntry(MediaHub hub) {
    final entry = _entryForHub(hub);
    if (entry == null || entry.request == AiAgent.tonightRequest) return null;
    if (_thinClient && !_canEditMirror) return null;
    if (entry.items.length >= AiHistory.maxItemsPerEntry) return null;
    return entry;
  }

  HubTrailingCard? _trailingCard(MediaHub hub) {
    final entry = _loadMoreEntry(hub);
    if (entry == null) return null;
    return switch (_more[entry.id]) {
      _MoreState.finding => HubTrailingCard(label: t.aiTab.findingMoreCard, spinner: true),
      _MoreState.none => HubTrailingCard(label: t.aiTab.noMoreCard, icon: Symbols.done_all_rounded),
      _MoreState.error => HubTrailingCard(
        label: t.common.retry,
        icon: Symbols.refresh_rounded,
        onTap: () => unawaited(_loadMoreInRow(entry)),
      ),
      null => HubTrailingCard(
        label: t.aiTab.loadMoreCard,
        icon: Symbols.playlist_add_rounded,
        onTap: () => unawaited(_loadMoreInRow(entry)),
      ),
    };
  }

  TvRailTrailing _tvTrailing(MediaHub hub) {
    final entry = _loadMoreEntry(hub);
    if (entry == null) return hub.more ? TvRailTrailing.viewAll : TvRailTrailing.none;
    return switch (_more[entry.id]) {
      _MoreState.finding => TvRailTrailing.findingMore,
      _MoreState.none => TvRailTrailing.noMore,
      _MoreState.error => TvRailTrailing.error,
      null => TvRailTrailing.loadMore,
    };
  }

  void _loadMoreHub(MediaHub hub) {
    final entry = _loadMoreEntry(hub);
    if (entry != null) unawaited(_loadMoreInRow(entry));
  }

  /// Load more: ask the same request again for titles not in the row and
  /// add them to its end, in the background; the card shows the progress.
  Future<void> _loadMoreInRow(AiHistoryEntry entry) async {
    if (_more[entry.id] == _MoreState.finding) return;
    ForkMotion.selection();
    setState(() => _more[entry.id] = _MoreState.finding);
    final _MoreState? outcome;
    if (_thinClient) {
      outcome = await _remoteLoadMore(entry);
    } else {
      outcome = await _localLoadMore(entry);
    }
    if (!mounted) return;
    setState(() => outcome == null ? _more.remove(entry.id) : _more[entry.id] = outcome);
    if (outcome == null) ForkMotion.success();
    if (outcome == _MoreState.error) ForkMotion.error();
  }

  /// Null when new picks were added.
  Future<_MoreState?> _localLoadMore(AiHistoryEntry entry) async {
    AiActivity.running.value++;
    try {
      final result = await _fetch(
        entry.request,
        ClaudeModel.sonnet,
        id: entry.id,
        useTitle: entry.title != null,
        keepTitle: entry.title,
        sentRequest: findMoreRequest(entry),
        excludeKeys: {...entry.items.map((i) => i.globalKey)},
      );
      final found = result.entry;
      if (found == null) return result.answer.error == null ? _MoreState.none : _MoreState.error;
      // The row as it is now: it may have changed while this ran.
      final current = await AiHistory.get(entry.id) ?? entry;
      final merged = mergeFindMore(current, found, append: true);
      if (merged.items.length == current.items.length) return _MoreState.none;
      await AiHistory.replace(merged);
      if (mounted) {
        setState(() {
          final i = _saved.indexWhere((e) => e.id == merged.id);
          if (i >= 0) _saved[i] = merged;
          if (_tonightRow?.id == merged.id) _tonightRow = merged;
        });
      }
      return null;
    } catch (e) {
      appLogger.w('AI: Load more failed', error: e);
      return _MoreState.error;
    } finally {
      AiActivity.running.value--;
    }
  }

  /// Phone: the TV runs it and answers on the AI channel; the new picks
  /// arrive with the next mirror snapshot.
  Future<_MoreState?> _remoteLoadMore(AiHistoryEntry entry) async {
    final remote = context.read<CompanionRemoteProvider>();
    final rid = 'more-${DateTime.now().microsecondsSinceEpoch}';
    final reply = remote.aiAnswers.firstWhere((d) => d['rid'] == rid).timeout(const Duration(minutes: 3));
    remote.sendCommand(RemoteCommandType.aiAction, data: {'action': 'loadMore', 'id': entry.id, 'rid': rid});
    try {
      final data = await reply;
      return switch (data['status']) {
        'done' => null,
        'none' => _MoreState.none,
        _ => _MoreState.error,
      };
    } catch (_) {
      return _MoreState.error;
    }
  }

  AiHistoryEntry? _entryForHub(MediaHub hub) => _rows.where((e) => _hubId(e) == hub.id).firstOrNull;

  List<MediaHub> get _hubs => [
    for (final row in _rows)
      MediaHub(
        id: _hubId(row),
        identifier: 'ai.answer',
        title: row.request == AiAgent.tonightRequest ? t.aiTab.tonight : row.label,
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
    _visible = true;
    AiActivity.unseen.value = 0;
    if (_hasKey == null) return;
    unawaited(_start());
  }

  @override
  void onTabHidden() => _visible = false;

  @override
  void focusActiveTabIfReady() {
    if (_rows.isNotEmpty) {
      _tvBrowseRailKey.currentState?.requestFocus();
    } else {
      _actionBarKey.currentState?.requestFocusOnFirst();
    }
  }

  void _navigateToSidebar() => MainScreenFocusScope.focusSidebarOf(context);

  /// Phone: its own requests still running on the TV (or failed), and
  /// whether the TV is busy with others (asked on the TV, Find more...).
  List<_PendingAsk> get _remotePending {
    final remote = context.read<CompanionRemoteProvider>();
    final mine = [
      for (final a in RemoteAiSession.instance.asks)
        if (a.status != 'done') _PendingAsk(a.request)..error = a.status == 'error' ? (a.error ?? '') : null,
    ];
    final running = remote.hostAiActivity.value?['running'] as int? ?? 0;
    final working = mine.where((a) => a.error == null).length;
    return [
      ...mine,
      if (_canEditMirror && running > working)
        _PendingAsk(t.cast.tvWorking(name: MirrorClient.instance.hostName ?? '')),
    ];
  }

  List<FocusableAction> _actions(Color color) => [
    if (_thinClient && !_canEditMirror)
      FocusableAction(
        debugLabel: 'AiOffline',
        onPressed: null,
        child: Text(
          t.cast.notConnected(name: MirrorClient.instance.hostName ?? t.companionRemote.unknownDevice),
          style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color.withValues(alpha: 0.7)),
        ),
      ),
    if (_thinClient)
      for (final ask in _remotePending)
        FocusableAction(
          debugLabel: 'AiPending',
          onPressed: null,
          child: _PendingChip(ask: ask, color: color),
        ),
    for (final ask in _pending)
      FocusableAction(
        debugLabel: 'AiPending',
        // Running requests just show progress; a failed one retries.
        onPressed: ask.error == null ? null : () => unawaited(_runInBackground(ask)),
        child: _PendingChip(ask: ask, color: color),
      ),
    FocusableAction(
      debugLabel: 'AiAsk',
      autofocus: _rows.isEmpty,
      onPressed: _thinClient ? () => unawaited(_ask()) : (_hasKey != true ? null : () => unawaited(_ask())),
      child: Padding(
        key: _askKey,
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
        onPressed: _newConversation,
      ),
    if (!_thinClient)
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

  List<MediaMenuExtraEntry> _pickMenuEntries(MediaItem item) {
    if (!_thinClient || !context.read<CompanionRemoteProvider>().isConnected) return const [];
    return [
      MediaMenuExtraEntry(icon: Symbols.cast_rounded, label: t.aiTab.playOnTv, onSelected: () => _playPick(item)),
    ];
  }

  /// Phone menu: play a pick straight away (on the TV while casting).
  void _playPick(MediaItem item) {
    if (item.kind == MediaKind.movie || item.kind == MediaKind.episode) {
      unawaited(navigateToVideoPlayer(context, metadata: item));
    } else {
      unawaited(navigateToMediaItem(context, item));
    }
  }

  Future<void> _openPick(MediaItem item) => openAiPick(context, item);

  /// Phones don't run the AI themselves: requests go to the TV app they're
  /// connected to (its key, index and history).
  static bool get _thinClient =>
      !PlatformDetector.isTV() &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context) {
    if (_thinClient) {
      context.watch<CompanionRemoteProvider>();
      if (!Customisation.isMirror) return const RemoteAiScreen();
    }
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
                  child: ItemMenuEntries(
                    build: _pickMenuEntries,
                    child: HubSection(
                      hub: hub,
                      trailingCard: _trailingCard(hub),
                      focusMemory: _hubFocusMemory,
                      icon: Symbols.auto_awesome_rounded,
                      // Phone: a tap plays (on the TV while casting); shows open.
                      onItemTap: _thinClient ? (item) => unawaited(_openPick(item)) : null,
                    ),
                  ),
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
                trailingForHub: _tvTrailing,
                onLoadMoreHub: _loadMoreHub,
                onRetryHub: _loadMoreHub,
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

/// A background request in the toolbar: a softly pulsing "Looking for: …"
/// while it runs, or "Retry: …" after it failed.
class _PendingChip extends StatefulWidget {
  const _PendingChip({required this.ask, required this.color});

  final _PendingAsk ask;
  final Color color;

  @override
  State<_PendingChip> createState() => _PendingChipState();
}

class _PendingChipState extends State<_PendingChip> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    lowerBound: 0.45,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failed = widget.ask.error != null;
    if (failed) {
      _pulse
        ..stop()
        ..value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
    final style = Theme.of(context).textTheme.titleSmall?.copyWith(color: widget.color.withValues(alpha: 0.85));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: _pulse,
            child: Icon(
              failed ? Symbols.refresh_rounded : Symbols.auto_awesome_rounded,
              size: 18,
              color: failed ? Theme.of(context).colorScheme.error : widget.color,
            ),
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(
              failed ? t.aiTab.retryChip(request: widget.ask.label) : t.aiTab.thinking(request: widget.ask.label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// A row's Load more card while busy or spent (see `AiScreenState._more`).
enum _MoreState { finding, none, error }
