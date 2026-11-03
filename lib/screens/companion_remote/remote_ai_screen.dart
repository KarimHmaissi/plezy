import 'dart:async';

import '../../utils/app_logger.dart';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../providers/companion_remote_provider.dart';
import '../../services/ai/ai_history.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/video_player_navigation.dart';
import '../../widgets/optimized_media_image.dart';
import 'mobile_remote_screen.dart';
import '../ai_pick_open.dart';

/// One request sent from this phone and what the TV has said about it.
class RemoteAiAsk {
  RemoteAiAsk(this.rid, this.request) : sentAt = DateTime.now();

  final String rid;
  final String request;
  final DateTime sentAt;
  String status = 'working';
  String? error;
  AiHistoryEntry? answer;

  /// What the TV says it's doing, and the answer's text as it's written.
  String? step;
  String? partial;
}

/// The phone's AI requests for this app run; the TV keeps the saved history.
class RemoteAiSession extends ChangeNotifier {
  RemoteAiSession._();
  static final RemoteAiSession instance = RemoteAiSession._();

  final List<RemoteAiAsk> asks = [];
  StreamSubscription<Map<String, dynamic>>? _sub;
  CompanionRemoteProvider? _remote;

  /// [ask], completing when the TV answers (or fails, or after 3 minutes).
  /// Sends [request] and completes with its ask once the TV answers (or
  /// fails), or still working after three minutes.
  Future<RemoteAiAsk> askAndWait(CompanionRemoteProvider remote, String request) {
    ask(remote, request);
    final mine = asks.first;
    final done = Completer<void>();
    void check() {
      if (mine.status == 'done' || mine.status == 'error') {
        if (!done.isCompleted) done.complete();
      }
    }

    addListener(check);
    return done.future
        .timeout(
          const Duration(minutes: 3),
          onTimeout: () {
            // Never left "looking for" forever: the reply may have been lost
            // in a reconnect (the answer still arrives with the TV's data).
            if (mine.status == 'working') {
              mine
                ..status = 'error'
                ..error = t.aiComposer.timedOut;
              notifyListeners();
            }
          },
        )
        .whenComplete(() => removeListener(check))
        .then((_) => mine);
  }

  /// Send a failed [failed] again (its card's Retry).
  void retry(CompanionRemoteProvider remote, RemoteAiAsk failed) {
    asks.remove(failed);
    ask(remote, failed.request);
  }

  /// Requests still running or failed: their cards sit above the answers.
  List<RemoteAiAsk> get pending => [
    for (final a in asks)
      if (a.status != 'done') a,
  ];

  /// The TV's saved answers arrived (a mirror snapshot): any request still
  /// waiting whose answer is among them is done, even if its reply was lost
  /// while the connection dropped.
  void reconcile(List<AiHistoryEntry> saved) {
    var changed = false;
    for (final ask in asks) {
      if (ask.status != 'working') continue;
      final answer = saved
          .where(
            (e) =>
                e.request.trim() == ask.request.trim() &&
                !e.createdAt.isBefore(ask.sentAt.subtract(const Duration(minutes: 1))),
          )
          .firstOrNull;
      if (answer == null) continue;
      ask
        ..status = 'done'
        ..answer = answer;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void ask(CompanionRemoteProvider remote, String request) {
    if (!identical(_remote, remote)) {
      _sub?.cancel();
      _remote = remote;
      _sub = remote.aiAnswers.listen(_onAnswer);
    }
    final rid = remote.askAi(request);
    appLogger.i('AI: request sent to the TV (rid $rid)');
    asks.insert(0, RemoteAiAsk(rid, request));
    notifyListeners();
  }

  void _onAnswer(Map<String, dynamic> data) {
    final ask = asks.where((a) => a.rid == data['rid']).firstOrNull;
    if (ask == null) return;
    ask.status = data['status'] as String? ?? 'error';
    if (ask.status == 'working') {
      ask.step = data['step'] as String? ?? ask.step;
      ask.partial = data['text'] as String? ?? ask.partial;
    } else if (ask.status == 'done') {
      ask.answer = AiHistoryEntry.fromJson(data);
      if (ask.answer == null) ask.status = 'error';
    } else if (ask.status == 'error') {
      ask.error = data['message'] as String? ?? '';
    }
    notifyListeners();
  }
}

/// The phone's AI tab: requests run on the connected TV app (its key, index
/// and history); picks play there with a tap.
class RemoteAiScreen extends StatefulWidget {
  const RemoteAiScreen({super.key});

  @override
  State<RemoteAiScreen> createState() => _RemoteAiScreenState();
}

class _RemoteAiScreenState extends State<RemoteAiScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send(CompanionRemoteProvider remote) {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    RemoteAiSession.instance.ask(remote, text);
    _controller.clear();
    FocusScope.of(context).unfocus();
  }

  String _hostName(CompanionRemoteProvider remote) => remote.connectedDevice?.name ?? t.companionRemote.unknownDevice;

  void _playOnHost(CompanionRemoteProvider remote, MediaItem item) {
    remote.castPlay(item);
    showAppSnackBar(context, t.cast.sending(title: item.title ?? '', name: _hostName(remote)));
  }

  Future<void> _showActions(CompanionRemoteProvider remote, MediaItem item) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Symbols.cast_rounded),
              title: Text(t.aiTab.playOnTv),
              onTap: () => Navigator.pop(context, 'play'),
            ),
            ListTile(
              leading: const Icon(Symbols.tv_rounded),
              title: Text(t.cast.showOnTv),
              onTap: () => Navigator.pop(context, 'open'),
            ),
            ListTile(
              leading: const Icon(Symbols.smartphone_rounded),
              title: Text(t.cast.playOnPhone),
              onTap: () => Navigator.pop(context, 'phone'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'play') _playOnHost(remote, item);
    if (choice == 'open') remote.castOpen(item);
    if (choice == 'phone') unawaited(navigateToVideoPlayer(context, metadata: item, allowCast: false));
  }

  @override
  Widget build(BuildContext context) {
    final remote = context.watch<CompanionRemoteProvider>();
    final theme = Theme.of(context);
    if (!(remote.isRemote && remote.isConnected)) {
      return Scaffold(
        appBar: AppBar(title: Text(t.navigation.ai)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Symbols.cast_rounded, size: 48, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(t.remoteAi.connectTitle, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(t.remoteAi.connectMessage, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (context) => const MobileRemoteScreen())),
                  icon: const Icon(Symbols.settings_remote_rounded),
                  label: Text(t.remoteAi.connect),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final name = _hostName(remote);
    return Scaffold(
      appBar: AppBar(title: Text(t.remoteAi.title(name: name))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(remote),
              decoration: InputDecoration(
                hintText: t.remoteAi.hint,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
                suffixIcon: IconButton(icon: const Icon(Symbols.send_rounded), onPressed: () => _send(remote)),
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: RemoteAiSession.instance,
              builder: (context, _) {
                final asks = RemoteAiSession.instance.asks;
                if (asks.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(t.remoteAi.empty, textAlign: TextAlign.center),
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [for (final ask in asks) ..._askTiles(remote, ask, name)],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _askTiles(CompanionRemoteProvider remote, RemoteAiAsk ask, String name) {
    final theme = Theme.of(context);
    final answer = ask.answer;
    return [
      ListTile(
        title: Text(answer?.label ?? ask.request, style: theme.textTheme.titleMedium),
        subtitle: switch (ask.status) {
          'working' => Text(t.remoteAi.working(name: name)),
          'error' => Text(
            t.remoteAi.error(message: ask.error ?? ''),
            style: TextStyle(color: theme.colorScheme.error),
          ),
          _ => answer?.intro == null ? null : Text(answer!.intro!),
        },
        trailing: ask.status == 'working'
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : null,
      ),
      if (answer != null)
        for (final item in answer.items)
          ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: OptimizedMediaImage.poster(
                client: context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId)),
                imagePath: item.posterThumb(),
                width: 44,
                height: 66,
              ),
            ),
            title: Text(item.year == null ? (item.title ?? '') : '${item.title} (${item.year})'),
            subtitle: answer.reasons[item.globalKey] == null
                ? null
                : Text(answer.reasons[item.globalKey]!, maxLines: 3, overflow: TextOverflow.ellipsis),
            isThreeLine: answer.reasons[item.globalKey] != null,
            onTap: () => unawaited(openAiPick(context, item)),
            onLongPress: () => unawaited(_showActions(remote, item)),
          ),
      const Divider(),
    ];
  }
}
