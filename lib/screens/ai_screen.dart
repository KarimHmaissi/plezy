import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../widgets/phone_nav_drawer.dart';
import '../focus/focusable_action_bar.dart';
import '../focus/hub_vertical_navigation.dart';
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
import '../services/companion_remote/phone_mode.dart';
import '../services/ai/ai_remote_asks.dart';
import '../media/media_kind.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/video_player_navigation.dart';
import '../models/companion_remote/remote_command.dart';
import '../services/companion_remote/mirror_sync.dart';
import '../theme/fork_motion.dart';
import '../theme/fork_spacing.dart';
import '../services/customisation/customisation_store.dart';
import '../services/ai/ai_activity.dart';
import '../services/ai/ai_agent.dart';
import '../services/ai/ai_briefing.dart';
import '../services/ai/ai_history.dart';
import 'ai_composer.dart';
import 'ai_pick_open.dart';
import 'ai_pick_peek.dart';
import '../services/ai/ai_pick_reasons.dart';
import '../services/settings_service.dart';
import '../services/ai/ai_home_refresher.dart';
import '../services/ai/ai_more_like_this.dart';
import '../services/ai/ai_rows.dart';
import '../services/ai/ai_suggestions.dart';
import '../services/ai/ai_week.dart';
import '../services/ai/ai_key_store.dart';
import '../services/ai/claude_client.dart';
import '../services/catalog/home_pins.dart';
import '../services/catalog/trakt_catalog_source.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../theme/mono_tokens.dart';
import '../widgets/fork_motion_widgets.dart';
import '../widgets/ai_answer_card.dart';
import '../widgets/media_card.dart';
import 'ai_answer_page.dart';
import 'ai_moods.dart';
import 'ai_suggested.dart';
import 'ai_week_card.dart';
import 'ai_tonight.dart';
import '../services/brain/brain_debug.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_menu.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/home_row_actions.dart';
import '../widgets/hub_section.dart';
import '../widgets/media_context_menu.dart' show ItemMenuEntries, ItemMenuHeader, MediaMenuExtraEntry, RowMenuEntries;
import '../widgets/side_navigation_rail.dart';
import '../widgets/system_bottom_inset.dart';
import '../widgets/toolbar_scrim.dart';
import '../widgets/tv_browse_rail.dart';
import '../widgets/tv_spotlight_scaffold.dart';
import 'companion_remote/remote_ai_screen.dart';
import 'libraries/state_messages.dart';
import 'settings/ai_settings_screen.dart';

/// Fork: [text] cut into pieces, each title of [items] it names (longest
/// first, first mention only) paired with its item.
List<(String, MediaItem?)> linkTitles(String text, List<MediaItem> items) {
  final titles = [...items]..sort((a, b) => (b.title ?? '').length.compareTo((a.title ?? '').length));
  final marks = <(int, int, MediaItem)>[];
  final lower = text.toLowerCase();
  for (final item in titles) {
    final name = (item.title ?? '').toLowerCase();
    if (name.length < 2) continue;
    var at = lower.indexOf(name);
    while (at >= 0 && marks.any((m) => at < m.$2 && at + name.length > m.$1)) {
      at = lower.indexOf(name, at + 1);
    }
    if (at >= 0) marks.add((at, at + name.length, item));
  }
  marks.sort((a, b) => a.$1.compareTo(b.$1));
  final out = <(String, MediaItem?)>[];
  var pos = 0;
  for (final (start, end, item) in marks) {
    if (start > pos) out.add((text.substring(pos, start), null));
    out.add((text.substring(start, end), item));
    pos = end;
  }
  if (pos < text.length) out.add((text.substring(pos), null));
  return out;
}

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

  /// What the helper is doing, and its answer as it's written.
  String? step;
  String? partial;
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

  /// Fork: today's briefing (made on the host once a day, mirrored to phones).
  AiHistoryEntry? _briefingRow;

  /// "Suggested for you": ready-made lists, and whether a new set is coming.
  List<AiSuggestion> _suggestions = const [];

  /// Your week in watching, Sunday to Tuesday.
  WatchWeek? _week;

  /// The week's posters, once they've loaded from the servers.
  List<MediaItem>? _weekItems;
  bool _makingLists = false;

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

  /// Touch/desktop rows by hub id: rows come and go at the top, so keys
  /// follow the row rather than its position.
  final Map<String, GlobalKey<HubSectionState>> _hubKeys = {};
  GlobalKey<HubSectionState> _hubKey(MediaHub hub) => _hubKeys.putIfAbsent(hub.id, GlobalKey.new);
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
    PhoneMode.changed.addListener(_onPhoneModeChanged);
    AiSuggestions.changed.addListener(_onSuggestionsChanged);
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
    PhoneMode.changed.removeListener(_onPhoneModeChanged);
    AiSuggestions.changed.removeListener(_onSuggestionsChanged);
    for (final r in _taps.values) {
      r.dispose();
    }
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

  /// The phone switched between mirroring its TV and running its own AI:
  /// start again from the new data and key.
  void _onPhoneModeChanged() {
    if (!mounted) return;
    setState(() {
      _hasKey = null;
      _briefingRow = null;
      _tonightRow = null;
      _tonightCache = null;
      _historyLoaded = false;
    });
    unawaited(_start());
  }

  Future<void> _onSuggestionsChanged() async {
    final saved = await AiSuggestions.cached();
    if (mounted) setState(() => _suggestions = saved.lists);
  }

  /// The week's card, counted on this device (no AI call); null when
  /// there's none, or counting takes too long for the first paint.
  static Future<WatchWeek?> _countWeek({Duration? within}) async {
    try {
      final counting = AiWeek.count();
      return await (within == null ? counting : counting.timeout(within, onTimeout: () => null));
    } catch (e) {
      appLogger.w('AI week: counting failed', error: e);
      return null;
    }
  }

  /// The week's card, then its posters (into the space kept for them).
  Future<void> _loadWeek() async {
    if (_thinClient) return;
    final clientFor = context.read<MultiServerProvider>().getClientForServer;
    final week = await _countWeek();
    if (!mounted) return;
    if (week?.start != _week?.start) _weekItems = null;
    setState(() => _week = week);
    if (week == null) return;
    final items = await AiWeek.posters(week, clientFor: clientFor);
    if (mounted && _week == week) setState(() => _weekItems = items);
  }

  void _hideWeek(WatchWeek week) {
    setState(() => _week = null);
    unawaited(AiWeek.dismiss(week));
  }

  /// The shelf as saved, then today's (a new set once a day, or now when
  /// [force]: "New lists").
  Future<void> _loadSuggestions({bool force = false}) async {
    if (_thinClient) return;
    final saved = await AiSuggestions.cached();
    if (!mounted) return;
    setState(() {
      _suggestions = saved.lists;
      _makingLists = force || saved.lists.isEmpty;
    });
    try {
      final today = await AiSuggestions.today(
        clientFor: context.read<MultiServerProvider>().getClientForServer,
        force: force,
      );
      if (!mounted) return;
      if (force && today.lists.isNotEmpty) ForkMotion.success();
      setState(() => _suggestions = today.lists);
    } finally {
      if (mounted) setState(() => _makingLists = false);
    }
  }

  /// A suggested list's page, with Keep and Not for me.
  void _openSuggestion(AiSuggestion list) {
    final navigator = Navigator.of(context);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (pageContext) => ItemMenuEntries(
          build: _pickMenuEntries,
          child: AiAnswerPage(
            entry: list.entry,
            onPick: (item) => unawaited(_openPick(item)),
            actions: [
              FilledButton.tonalIcon(
                icon: const AppIcon(Symbols.bookmark_add_rounded, fill: 1, size: 18),
                label: Text(t.aiTab.keepList),
                onPressed: () async {
                  final kept = await AiSuggestions.keep(list);
                  ForkMotion.success();
                  navigator.pop();
                  if (!mounted) return;
                  setState(() {
                    _saved.insert(0, kept);
                    _savedTotal++;
                    _askedThisVisit++;
                  });
                  showAppSnackBar(context, t.aiTab.keptList);
                },
              ),
              OutlinedButton.icon(
                icon: const AppIcon(Symbols.visibility_off_rounded, size: 18),
                label: Text(t.aiTab.notForMe),
                onPressed: () async {
                  await AiSuggestions.dismiss(list);
                  navigator.pop();
                  if (mounted) showAppSnackBar(context, t.aiTab.hiddenList);
                },
              ),
            ],
          ),
        ),
      ),
    );
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
    if (!_historyLoaded) await _loadHistory(withTop: _cardsInline);
    final key = await AiKeyStore.read();
    if (!mounted) return;
    setState(() => _hasKey = key != null);
    if (key != null) {
      // Touch screens show Tonight's cards; TV keeps its Tonight row.
      if (_cardsInline) {
        unawaited(_briefing());
        unawaited(_loadSuggestions());
        unawaited(_loadWeek());
      } else {
        await _tonight();
      }
    }
  }

  /// Today's briefing; [force] writes a new one (pull to refresh).
  Future<void> _briefing({bool force = false}) async {
    if (!AiBriefing.enabled) return;
    final servers = context.read<MultiServerProvider>();
    final cached = await AiBriefing.cached();
    if (mounted && cached != null && _briefingRow == null) setState(() => _briefingRow = cached);
    if (_thinClient) return;
    final entry = await AiBriefing.today(clientFor: servers.getClientForServer, force: force);
    if (mounted && entry != null) {
      if (force && entry.createdAt != _briefingRow?.createdAt) ForkMotion.success();
      setState(() => _briefingRow = entry);
    }
  }

  /// Pull to refresh and the toolbar's refresh: new Tonight picks and a new
  /// briefing.
  Future<void> _refreshAll() => _cardsInline ? _pullRefresh() : _tonight(refresh: true);

  bool _confirming = false;

  /// Touch screens: free reloads straight away, then a confirm before
  /// anything that costs a model call (a new Tonight).
  Future<void> _pullRefresh() async {
    await Future.wait([_loadHistory(), _loadWeek()]);
    if (!mounted || _confirming) return;
    if (_thinClient ? !_canEditMirror : _hasKey != true) return;
    // After the refresh indicator settles.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_confirmNewTonight()));
  }

  Future<void> _confirmNewTonight() async {
    if (!mounted || _confirming) return;
    _confirming = true;
    final bool? yes;
    try {
      yes = await showModalBottomSheet<bool>(
        context: context,
        useSafeArea: true,
        backgroundColor: tokens(context).surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(tokens(context).radiusLg)),
        ),
        builder: (context) => const _TonightConfirm(),
      );
    } finally {
      _confirming = false;
    }
    if (yes != true || !mounted) return;
    if (!_thinClient) return _briefing(force: true);
    // The TV makes it; the new cards arrive with the next snapshot.
    final remote = context.read<CompanionRemoteProvider>();
    final rid = 'tonight-${DateTime.now().microsecondsSinceEpoch}';
    remote.sendCommand(RemoteCommandType.aiAction, data: {'action': 'tonight', 'rid': rid});
  }

  /// The saved answers; with [withTop] (the first load on touch screens)
  /// also what sits above them, so the page appears whole rather than
  /// growing and jumping as each part arrives.
  Future<void> _loadHistory({bool withTop = false}) async {
    try {
      final total = await AiHistory.count();
      final page = await AiHistory.page(limit: _pageSize);
      final briefing = AiBriefing.enabled ? await AiBriefing.cached() : null;
      if (_thinClient) RemoteAiSession.instance.reconcile(page);
      if (withTop && !_thinClient) {
        final (key, shelf, week) = await (
          AiKeyStore.read(),
          AiSuggestions.cached(),
          _countWeek(within: const Duration(milliseconds: 400)),
        ).wait;
        _hasKey = key != null;
        _suggestions = shelf.lists;
        _week = week;
      }
      if (!mounted) return;
      setState(() {
        _historyLoaded = true;
        _briefingRow = briefing ?? _briefingRow;
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

  /// Opens the composer; with [request] (a mood chip) it asks straight away.
  Future<void> _ask({String? request}) async {
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
    // A mood starts afresh rather than following up the conversation.
    final previous = request == null ? List.of(_conversation) : <({String request, AiAnswer answer})>[];
    _PendingAsk? lastFailed;
    await AiComposer.open(
      context,
      followUpOf: previous.isEmpty ? null : previous.last.request,
      recent: {
        for (final r in _rows)
          if (r.request != AiAgent.tonightRequest) r.request,
      }.take(5).toList(),
      posters: [for (final r in _rows.take(6)) ...r.items.take(8)],
      origin: _rectOf(_askKey),
      autoRequest: request,
      run: (text) async {
        // The composer's send moment, then the answer card takes over: as
        // soon as text streams in, or after [_handoff] at most.
        if (remote != null) {
          final session = RemoteAiSession.instance;
          session.ask(remote, text);
          final mine = session.asks.first;
          await _waitFor(session, () => mine.partial != null || mine.status != 'working');
          if (mine.status == 'error') {
            return AiComposerOutcome(error: (mine.error?.isNotEmpty ?? false) ? mine.error : t.aiTab.noPicks);
          }
          return const AiComposerOutcome();
        }
        // A retry from the composer replaces its failed attempt.
        final failed = lastFailed;
        if (failed != null && mounted) setState(() => _pending.remove(failed));
        final ask = _PendingAsk(text, previous: previous);
        final running = _runInBackground(ask);
        final progress = ValueNotifier(0);
        void tick() => progress.value++;
        _progressTick = tick;
        await Future.any([running, _waitFor(progress, () => ask.partial != null || ask.error != null)]);
        _progressTick = null;
        progress.dispose();
        lastFailed = ask.error != null ? ask : null;
        if (ask.error != null) return AiComposerOutcome(error: ask.error);
        return const AiComposerOutcome();
      },
    );
  }

  /// How long the composer's send moment lasts at most before the inline
  /// card takes over.
  static const Duration _handoff = Duration(milliseconds: 1500);
  VoidCallback? _progressTick;

  /// Completes when [done] holds (checked on every change of [source]) or
  /// after [_handoff].
  static Future<void> _waitFor(Listenable source, bool Function() done) {
    if (done()) return Future.value();
    final completer = Completer<void>();
    void check() {
      if (done() && !completer.isCompleted) completer.complete();
    }

    source.addListener(check);
    return completer.future.timeout(_handoff, onTimeout: () {}).whenComplete(() => source.removeListener(check));
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
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            ask.step = p.step ?? ask.step;
            ask.partial = p.text ?? ask.partial;
          });
          _progressTick?.call();
        },
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
        // A fresh ask (a mood) starts a new conversation.
        if (ask.previous.isEmpty) _conversation.clear();
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
    if (entry == null || entry.request == AiAgent.tonightRequest || entry.id == AiBriefing.entryId) return const [];
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
    void Function(AiProgress progress)? onProgress,
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
      onProgress: onProgress,
    );
  }

  /// Rows in order: today's briefing, this visit's answers, Tonight, then
  /// older saved ones.
  List<AiHistoryEntry> get _rows => [
    ..._saved.take(_askedThisVisit),
    if (!_cardsInline) ?_tonightRow,
    ..._saved.skip(_askedThisVisit),
  ];

  static String _hubId(AiHistoryEntry entry) => 'aitab:${entry.id}';

  /// Load more card state per answer id; absent means ready.
  final Map<String, _MoreState> _more = {};

  /// The answer [hub] shows when it can take a Load more card.
  AiHistoryEntry? _loadMoreEntry(MediaHub hub) {
    final entry = _entryForHub(hub);
    // Tonight, the briefing and written answers aren't lists to grow.
    if (entry == null || entry.request == AiAgent.tonightRequest || entry.answer != null) return null;
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
    final entry = _entryForHub(hub);
    // An answered question keeps its answer up; a pick shows its reason.
    _focusedReason.value = entry?.answer ?? entry?.reasons[item.globalKey];
  }

  String? get _headline => _rows.firstOrNull?.answer ?? _rows.firstOrNull?.intro;

  /// Tonight's cards, when there are any to show (touch screens).
  AiHistoryEntry? get _tonightCards => _cardsInline && (_briefingRow?.items.isNotEmpty ?? false) ? _briefingRow : null;

  /// Touch screens and desktop show the answer cards (TV keeps its spotlight).
  static bool get _cardsInline => !PlatformDetector.isTV();

  /// Requests still running (or failed) as tiles above the answers.
  List<Widget> _pendingCards() {
    if (!_cardsInline) return const [];
    Widget tile(
      Key key,
      String question,
      String? partial,
      String? step,
      bool running,
      String? error,
      VoidCallback retry,
    ) => _rowSizedTile(
      (height, band) => AiAnswerTile(
        key: key,
        question: question,
        headline: partial == null || partial.trim().isEmpty ? null : _firstSentence(partial),
        step: step ?? t.aiTab.starting,
        running: running,
        error: error,
        height: height,
        band: band,
        onTap: error == null ? null : retry,
      ),
    );
    if (_thinClient) {
      final remote = context.read<CompanionRemoteProvider>();
      final session = RemoteAiSession.instance;
      return [
        for (final a in session.asks)
          if (a.status != 'done')
            tile(
              ValueKey('ask-${a.rid}'),
              a.request,
              a.partial,
              a.step,
              a.status == 'working',
              a.status == 'error' ? ((a.error?.isNotEmpty ?? false) ? a.error : t.aiTab.noPicks) : null,
              () => session.retry(remote, a),
            ),
      ];
    }
    return [
      for (final ask in _pending)
        tile(
          ObjectKey(ask),
          ask.label,
          ask.partial,
          ask.step,
          ask.error == null,
          ask.error == null ? null : (ask.error!.isEmpty ? t.aiTab.noPicks : ask.error),
          () => unawaited(_runInBackground(ask)),
        ),
    ];
  }

  /// The hairline between answer blocks; with the row's own bottom gap it
  /// leaves about 48 dp between one block's posters and the next title.
  Widget _blockDivider() {
    final spacing = ForkSpacing.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(spacing.edgeInset, 0, spacing.edgeInset, 12),
      child: Divider(height: 1, thickness: 1, color: tokens(context).outline),
    );
  }

  /// A running (or failed) request's block: a title like a row's, then the
  /// card, and its posters once they land.
  Widget _pendingBlock(Widget card, {required bool divider}) {
    final spacing = ForkSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (divider) _blockDivider(),
        Padding(
          padding: EdgeInsets.fromLTRB(spacing.edgeInset, 0, spacing.edgeInset, spacing.rowGap),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIcon(Symbols.auto_awesome_rounded, fill: 1, size: spacing.titleSize),
                  const SizedBox(width: 8),
                  Flexible(child: Text(t.aiTab.working, style: spacing.titleStyle(context), maxLines: 1)),
                ],
              ),
              SizedBox(height: spacing.titleGap),
              card,
            ],
          ),
        ),
      ],
    );
  }

  /// "Top pick" on the strongest matches' posters, and how far the user got
  /// with a pick (Watched, In progress, Rewatch), from the history brain.
  List<String> Function(MediaItem item)? _badgesFor(MediaHub hub) {
    final entry = _entryForHub(hub);
    final top = entry?.topPicks ?? const {};
    final seen = entry?.watchState ?? const {};
    if (top.isEmpty && seen.isEmpty) return null;
    return (item) => [
      if (top.containsKey(item.globalKey)) t.aiTab.topPick,
      ?switch (seen[item.globalKey]) {
        'inProgress' => t.aiTab.badgeInProgress,
        'rewatch' => t.aiTab.badgeRewatch,
        'watched' => t.aiTab.badgeWatched,
        _ => null,
      },
    ];
  }

  /// The answer as the first tile of its row; a tap opens its page.
  Widget Function(double height, double band)? _answerTile(MediaHub hub) {
    final entry = _entryForHub(hub);
    final text = entry?.cardText;
    if (entry == null || text == null || text.trim().isEmpty) return null;
    final top =
        entry.items.where((i) => entry.topPicks.containsKey(i.globalKey)).firstOrNull ?? entry.items.firstOrNull;
    return (height, band) => AiAnswerTile(
      key: ValueKey('tile-${entry.id}'),
      question: entry.request == AiAgent.tonightRequest ? t.aiTab.tonight : entry.request,
      headline: (entry.headline?.trim().isNotEmpty ?? false) ? entry.headline : _firstSentence(text),
      art: top,
      count: entry.items.length,
      height: height,
      band: band,
      onTap: () => _openAnswer(hub, entry),
    );
  }

  /// The row title's tap on touch screens: the same answer page as its tile.
  VoidCallback? _answerOpener(MediaHub hub) {
    final entry = _entryForHub(hub);
    if (!_cardsInline || entry == null || (entry.cardText ?? '').trim().isEmpty) return null;
    return () => _openAnswer(hub, entry);
  }

  static String _firstSentence(String text) {
    final m = RegExp(r'^.+?[.!?](?=\s|$)', dotAll: true).firstMatch(text.trim());
    return m?.group(0) ?? text.trim();
  }

  /// The answer page, with the row's menus (long-press, ⋯) as on this page.
  void _openAnswer(MediaHub hub, AiHistoryEntry entry) {
    final rowEntries = _rowMenuEntries(hub);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ItemMenuEntries(
          build: _pickMenuEntries,
          child: ItemMenuHeader(
            build: (item) => _thinClient ? _peekHeader(hub, item) : null,
            child: AiAnswerPage(
              entry: entry,
              onPick: (item) => unawaited(_openPick(item)),
              onFollowUp: (f) => unawaited(_followUp(entry, f)),
              rowEntries: rowEntries,
              badgesFor: _badgesFor(hub),
              linkify: (text, style) {
                final link = style?.copyWith(fontWeight: FontWeight.w600);
                return [
                  for (final (piece, item) in linkTitles(text, entry.items))
                    item == null
                        ? TextSpan(text: piece)
                        : TextSpan(text: piece, style: link, recognizer: _tapRecognizer(item)),
                ];
              },
            ),
          ),
        ),
      ),
    );
  }

  /// An answer without titles: just its tile, at a row's height.
  Widget? _tileOnly(MediaHub hub) {
    if (hub.items.isNotEmpty) return null;
    final tile = _answerTile(hub);
    if (tile == null) return null;
    return _rowSizedTile(tile);
  }

  /// A tile sized as a poster row's cards would be at this width.
  Widget _rowSizedTile(Widget Function(double height, double band) tile) => LayoutBuilder(
    builder: (context, constraints) {
      final spacing = ForkSpacing.of(context);
      final width = spacing.cardWidth(constraints.maxWidth + 2 * spacing.edgeInset, wide: false);
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: tile((width - 6) * 1.5, MediaCard.rowCaptionBandHeight(context)),
      );
    },
  );

  /// The ⋯ next to an answer's title: its row actions (Add to Home, Find
  /// more, Replace, Delete), as the long-press menu also lists them.
  Widget? _rowMenuButton(MediaHub hub) {
    if (_rowMenuEntries(hub).isEmpty) return null;
    return IconButton(
      tooltip: t.aiTab.more,
      visualDensity: VisualDensity.compact,
      icon: AppIcon(Symbols.more_horiz_rounded, fill: 1, size: ForkSpacing.of(context).titleSize),
      onPressed: () async {
        final entries = _rowMenuEntries(hub);
        final picked = await showAdaptiveAppMenu<int>(
          context,
          title: hub.title,
          entries: [for (final (i, e) in entries.indexed) AppMenuItem(value: i, icon: e.icon, label: e.label)],
        );
        if (picked != null && picked < entries.length) entries[picked].onSelected();
      },
    );
  }

  /// A follow-up chip: a new request that carries the answer it refines.
  Future<void> _followUp(AiHistoryEntry entry, String followUp) async {
    final request = '$followUp (refining: ${entry.request})';
    if (_thinClient) {
      if (!_canEditMirror) return _ask();
      RemoteAiSession.instance.ask(context.read<CompanionRemoteProvider>(), request);
      return;
    }
    if (_hasKey != true) return;
    await _runInBackground(_PendingAsk(request, previous: List.of(_conversation)));
  }

  final Map<String, TapGestureRecognizer> _taps = {};
  TapGestureRecognizer _tapRecognizer(MediaItem item) =>
      _taps.putIfAbsent(item.globalKey, () => TapGestureRecognizer()..onTap = () => unawaited(_openPick(item)));

  bool get _hasMore => _saved.length < _savedTotal;

  @override
  void manualRefresh() => unawaited(_refreshAll());

  @override
  void fullRefresh() => unawaited(_refreshAll());

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
      if (PlatformDetector.isTV()) {
        _tvBrowseRailKey.currentState?.requestFocus();
      } else {
        _focusFirstHub();
      }
    } else {
      _actionBarKey.currentState?.requestFocusOnFirst();
    }
  }

  void _navigateToSidebar() => MainScreenFocusScope.focusSidebarOf(context);

  void _focusFirstHub() {
    final first = _hubs.firstOrNull;
    if (first != null) _hubKeys[first.id]?.currentState?.requestFocusFromMemory();
  }

  /// Phone: its own requests still running on the TV (or failed), and
  /// whether the TV is busy with others (asked on the TV, Find more...).
  List<_PendingAsk> get _remotePending {
    final remote = context.read<CompanionRemoteProvider>();
    final mine = [
      // With cards inline the phone's own requests are cards, not chips.
      for (final a in RemoteAiSession.instance.asks)
        if (a.status != 'done' && !_cardsInline)
          _PendingAsk(a.request)..error = a.status == 'error' ? (a.error ?? '') : null,
    ];
    final running = remote.hostAiActivity.value?['running'] as int? ?? 0;
    final working = RemoteAiSession.instance.asks.where((a) => a.status == 'working').length;
    return [
      ...mine,
      if (_canEditMirror && running > working)
        _PendingAsk(t.cast.tvWorking(name: MirrorClient.instance.hostName ?? '')),
    ];
  }

  /// On phones the icon-only actions move into the side drawer, next to
  /// the shared Search / remote / avatar set.
  List<FocusableAction> _actions(Color color) {
    final phone = PlatformDetector.isMobile(context);
    final canRefresh = !_thinClient && !_busy && _hasKey == true;
    return [
      if (_thinClient && !_canEditMirror)
        FocusableAction(
          debugLabel: 'AiOffline',
          onPressed: null,
          child: Text(
            t.cast.notConnected(name: MirrorClient.instance.hostName ?? t.companionRemote.unknownDevice),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color.withValues(alpha: 0.7)),
          ),
        ),
      // Touch and desktop show requests as cards above the answers; the
      // toolbar keeps only "the TV is busy with others".
      if (_thinClient)
        for (final ask in _remotePending)
          FocusableAction(
            debugLabel: 'AiPending',
            onPressed: null,
            child: _PendingChip(ask: ask, color: color),
          ),
      if (!_cardsInline)
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
        onPressed: _thinClient || _hasKey == true
            ? () => unawaited(_ask())
            : _hasKey == false
            ? _openKeySettings
            : null,
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
      if (phone)
        ...phoneTabActions(
          context,
          color: color,
          onRefresh: canRefresh ? () => unawaited(_refreshAll()) : null,
          extras: [
            if (_conversation.isNotEmpty) (Symbols.add_comment_rounded, t.aiTab.newConversation, _newConversation),
            if (_hasMore) (Symbols.expand_more_rounded, t.aiTab.loadMore, () => unawaited(_loadMore())),
          ],
        ),
      if (!phone && _conversation.isNotEmpty)
        FocusableAction(
          icon: Symbols.add_comment_rounded,
          iconColor: color,
          tooltip: t.aiTab.newConversation,
          onPressed: _newConversation,
        ),
      if (!phone && !_thinClient)
        FocusableAction(
          icon: Symbols.refresh_rounded,
          iconColor: color,
          tooltip: t.aiTab.refreshTonight,
          onPressed: _busy || _hasKey != true ? null : () => unawaited(_refreshAll()),
        ),
      if (!phone && _hasMore)
        FocusableAction(
          icon: Symbols.expand_more_rounded,
          iconColor: color,
          tooltip: t.aiTab.loadMore,
          onPressed: () => unawaited(_loadMore()),
        ),
    ];
  }

  /// Settings ▸ AI, to add a key; picks up a new one on the way back.
  void _openKeySettings() => unawaited(
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AiSettingsScreen())).then((_) => _start()),
  );

  Widget? _message() {
    // Nothing until the saved answers are read (a moment), rather than the
    // empty state flashing first.
    if (!_historyLoaded) return const SizedBox.shrink();
    // Without a key the saved answers still show; Ask leads to the key.
    if (_hasKey == false && _rows.isEmpty) {
      return Center(
        child: EmptyStateWidget(
          message: t.aiTab.noKeyTitle,
          subtitle: t.aiTab.noKeyMessage,
          icon: Symbols.key_rounded,
          actionLabel: t.ai.settingsTitle,
          onAction: _openKeySettings,
        ),
      );
    }
    if (_rows.isEmpty && _tonightCards == null) {
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

  /// The top of a pick's long-press menu; a reason the answer didn't write
  /// is made on the TV (or here, on a host) and saved with the answer.
  Widget? _peekHeader(MediaHub hub, MediaItem item) {
    final entry = _entryForHub(hub);
    final key = item.globalKey;
    final reason = entry?.reasons[key];
    Future<String?> Function()? load;
    if (entry != null && (reason == null || reason.trim().isEmpty)) {
      load = _thinClient ? () => _remoteReason(entry.id, key) : () => AiPickReasons.reasonFor(entry.id, key);
    }
    return AiPickPeekHeader(
      item: item,
      reason: reason,
      loadReason: load,
      topPick: entry?.topPicks[key],
      spotlight: entry?.spotlights[key],
      onPlay: () => _playPick(item),
      onDetails: () => unawaited(_openPick(item)),
    );
  }

  Future<String?> _remoteReason(String entryId, String key) async {
    final remote = context.read<CompanionRemoteProvider>();
    if (!remote.isConnected) return null;
    final rid = 'reason-${DateTime.now().microsecondsSinceEpoch}';
    final reply = remote.aiAnswers.firstWhere((d) => d['rid'] == rid).timeout(const Duration(seconds: 45));
    remote.sendCommand(RemoteCommandType.aiAction, data: {'action': 'reason', 'id': entryId, 'key': key, 'rid': rid});
    try {
      final data = await reply;
      return data['status'] == 'done' ? data['text'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  /// A phone set to mirror its TV doesn't run the AI itself: requests go to
  /// the TV app it's connected to (its key, index and history).
  static bool get _thinClient => PhoneMode.mirrorsTv;

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) BrainDebug.clientFor ??= context.read<MultiServerProvider>().getClientForServer;
    if (_thinClient) {
      context.watch<CompanionRemoteProvider>();
      if (!Customisation.isMirror) return const RemoteAiScreen();
    }
    final hubs = _hubs;
    final pendingCards = _pendingCards();
    final message = pendingCards.isEmpty ? _message() : null;
    final color = Theme.of(context).colorScheme.onSurface;
    if (!PlatformDetector.isTV()) {
      return Scaffold(
        body: RefreshIndicator(
          // Pull to refresh does what the toolbar's refresh does: new Tonight
          // picks (a phone mirroring its TV reloads the TV's answers).
          onRefresh: ForkMotion.refreshing(() => _thinClient || _hasKey == true ? _pullRefresh() : _start()),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              DesktopSliverAppBar(
                title: Text(t.navigation.ai),
                pinned: false,
                floating: true,
                snap: true,
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                surfaceTintColor: Colors.transparent,
                shadowColor: Colors.transparent,
                scrolledUnderElevation: 0,
                actions: [
                  FocusableActionBar(key: _actionBarKey, onNavigateDown: _focusFirstHub, actions: _actions(color)),
                ],
              ),
              if (message != null)
                SliverFillRemaining(child: message)
              else ...[
                if (_thinClient || _hasKey == true)
                  SliverToBoxAdapter(
                    child: AiMoodChips(onPick: (mood) => unawaited(_ask(request: mood.request))),
                  ),
                if (_week case final week? when !_thinClient)
                  SliverToBoxAdapter(
                    child: ForkEntrance(
                      key: ValueKey('week-${week.start}'),
                      child: AiWeekCard(
                        week: week,
                        items: _weekItems,
                        onItemTap: (item) => unawaited(_openPick(item)),
                        onHide: () => _hideWeek(week),
                      ),
                    ),
                  ),
                // One block per answer: title, what was asked and the write-up,
                // then its posters; a hairline between blocks.
                if (_tonightCards case final tonight?)
                  SliverToBoxAdapter(
                    child: ItemMenuEntries(
                      build: _pickMenuEntries,
                      child: AiTonightBlock(
                        entry: tonight,
                        onItemTap: _thinClient ? (item) => unawaited(_openPick(item)) : null,
                      ),
                    ),
                  ),
                if (!_thinClient && (_suggestions.isNotEmpty || _makingLists))
                  SliverToBoxAdapter(
                    child: AiSuggestedShelf(
                      lists: _suggestions,
                      making: _makingLists,
                      onOpen: _openSuggestion,
                      onNewLists: _hasKey == true ? () => unawaited(_loadSuggestions(force: true)) : null,
                    ),
                  ),
                for (final (n, card) in pendingCards.indexed)
                  SliverToBoxAdapter(child: _pendingBlock(card, divider: n > 0 || _tonightCards != null)),
                for (var i = 0; i < hubs.length; i++) ...[
                  if (i > 0 || pendingCards.isNotEmpty || _tonightCards != null)
                    SliverToBoxAdapter(child: _blockDivider()),
                  SliverToBoxAdapter(
                    // Rows rise in as the page opens, and a new answer as it lands.
                    child: ForkEntrance(
                      key: ValueKey('enter-${hubs[i].id}'),
                      // Rows scrolled to later rise in without waiting.
                      index: i < ForkMotion.staggerMax ? i : 0,
                      child: RowMenuEntries(
                        entries: _rowMenuEntries(hubs[i]),
                        child: ItemMenuEntries(
                          build: _pickMenuEntries,
                          child: ItemMenuHeader(
                            // Phone: why it was picked, above the usual entries.
                            build: (item) => _thinClient ? _peekHeader(hubs[i], item) : null,
                            child: HubSection(
                              key: _hubKey(hubs[i]),
                              hub: hubs[i],
                              trailingCard: _trailingCard(hubs[i]),
                              belowTitle: _tileOnly(hubs[i]),
                              leadingTile: _answerTile(hubs[i]),
                              onTitleTap: _answerOpener(hubs[i]),
                              badgesFor: _badgesFor(hubs[i]),
                              titleTrailing: _cardsInline ? _rowMenuButton(hubs[i]) : null,
                              focusMemory: _hubFocusMemory,
                              icon: Symbols.auto_awesome_rounded,
                              // Phone: a tap plays (on the TV while casting); shows open.
                              onItemTap: _thinClient ? (item) => unawaited(_openPick(item)) : null,
                              onVerticalNavigation: (isUp) => navigateVerticalHubRows(
                                hubCount: hubs.length,
                                hubIndex: i,
                                isUp: isUp,
                                onTopBoundary: () => _actionBarKey.currentState?.requestFocusOnFirst(),
                                requestFocus: (target) => _hubKey(hubs[target]).currentState?.requestFocusFromMemory(),
                              ),
                              onNavigateToSidebar: _navigateToSidebar,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
              if (message == null && _hasMore)
                SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(ForkSpacing.of(context).edgeInset),
                      child: TextButton.icon(
                        onPressed: () => unawaited(_loadMore()),
                        icon: const Icon(Symbols.expand_more_rounded),
                        label: Text(t.aiTab.loadMore),
                      ),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
              // Clear of the Android navigation bar / iOS home indicator.
              const SliverSystemBottomInset(),
            ],
          ),
        ),
      );
    }
    // The TV rail needs cards; an answer without any shows as the headline.
    final tvHubs = [
      for (final h in hubs)
        if (h.items.isNotEmpty) h,
    ];
    return TvSpotlightScaffold(
      hubs: tvHubs,
      spotlightListenable: _spotlight,
      resolveSpotlight: () => _spotlight.resolve(tvHubs),
      resolveClient: (spotlight) => context.tryGetMediaClientForServer(serverIdOrNull(spotlight?.serverId)),
      condensedListenable: _tvRowsExpanded,
      foreground: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          ?message,
          if (tvHubs.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: TvBrowseRail(
                key: _tvBrowseRailKey,
                hubs: tvHubs,
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
                                  maxLines: 3,
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

/// The pull-to-refresh confirm: a small sheet at the thumb, No / Yes.
class _TonightConfirm extends StatelessWidget {
  const _TonightConfirm();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final spacing = ForkSpacing.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(spacing.edgeInset, 20, spacing.edgeInset, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.aiTab.tonightConfirm, style: theme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(t.aiTab.tonightConfirmBody, style: theme.bodyMedium?.copyWith(color: tokens(context).textMuted)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.no)),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.common.yes)),
            ],
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
