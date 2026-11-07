import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../media/ids.dart';
import '../../providers/catalog_sources_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/ai/ai_agent.dart';
import '../../services/catalog/trakt_catalog_source.dart';
import '../../services/library_index/library_index.dart';
import '../../services/reel/reel_ledger.dart';
import '../../utils/media_navigation_helper.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';

/// A plain test screen for the AI helper (before the AI tab exists): runs
/// one request and lists the picks with their reasons; select one to open it.
class AiTryScreen extends StatefulWidget {
  const AiTryScreen({super.key, required this.request});

  final String request;

  @override
  State<AiTryScreen> createState() => _AiTryScreenState();
}

class _AiTryScreenState extends State<AiTryScreen> {
  AiAnswer? _answer;
  late final AiAgent _agent;

  @override
  void initState() {
    super.initState();
    final trakt = context.read<CatalogSourcesProvider?>()?.connectedSources.whereType<TraktCatalogSource>().firstOrNull;
    _agent = AiAgent(index: LibraryIndex.instance, trakt: trakt?.client, ledger: ReelLedger.instance.snapshot);
    unawaited(_run());
  }

  @override
  void dispose() {
    _agent.close();
    super.dispose();
  }

  Future<void> _run() async {
    final answer = await _agent.ask(widget.request);
    if (mounted) setState(() => _answer = answer);
  }

  Future<void> _open(String serverId, String ratingKey) async {
    final client = context.read<MultiServerProvider>().getClientForServer(ServerId(serverId));
    final item = await client?.fetchItem(ratingKey);
    if (!mounted) return;
    if (item == null) {
      showErrorSnackBar(context, 'Couldn\'t open that title');
      return;
    }
    await navigateToMediaItem(context, item);
  }

  @override
  Widget build(BuildContext context) {
    final a = _answer;
    return FocusedScrollScaffold(
      title: Text(widget.request),
      slivers: [
        SliverList.list(
          children: [
            if (a == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (a.error != null) ListTile(title: Text(a.error!)),
              if (a.intro != null) ListTile(title: Text(a.intro!, style: Theme.of(context).textTheme.titleMedium)),
              for (final (i, pick) in a.picks.indexed)
                FocusableListTile(
                  autofocus: i == 0,
                  leading: AppIcon(pick.title.type == 'show' ? Symbols.tv_rounded : Symbols.movie_rounded, fill: 1),
                  title: Text('${pick.title.title}${pick.title.year == null ? '' : ' (${pick.title.year})'}'),
                  subtitle: Text(pick.reason),
                  onTap: () => unawaited(_open(pick.title.serverId, pick.title.ratingKey)),
                ),
              if (a.text.isNotEmpty && a.picks.isEmpty) ListTile(subtitle: Text(a.text)),
              ListTile(
                subtitle: Text(
                  '${(a.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s · ${a.toolCalls.length} tool calls · '
                  '\$${a.cost.toStringAsFixed(4)}',
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
