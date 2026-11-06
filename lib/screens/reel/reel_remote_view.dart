import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../media/ids.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../providers/companion_remote_provider.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/optimized_media_image.dart';
import '../../widgets/stat_chip.dart';

/// Fork: the Fold's On TV mode. The TV's Reel plays; the phone shows its
/// card and the next three and sends `reelStep` / `reelAction`. The phone
/// plays nothing. Built from the app's own theme and widgets.
class ReelRemoteView extends StatefulWidget {
  const ReelRemoteView({super.key, this.deck});

  /// The deck the phone was on, opened on the TV.
  final String? deck;

  @override
  State<ReelRemoteView> createState() => _ReelRemoteViewState();
}

class _ReelRemoteViewState extends State<ReelRemoteView> {
  late final CompanionRemoteProvider _remote = context.read<CompanionRemoteProvider>();
  Timer? _waitTimer;
  bool _waitedLong = false;

  @override
  void initState() {
    super.initState();
    _open(deck: widget.deck);
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    super.dispose();
  }

  void _open({String? deck}) {
    _remote.sendCommand(RemoteCommandType.tabReel);
    _remote.sendCommand(RemoteCommandType.reelOpen, data: {'deck': ?deck});
    _waitTimer?.cancel();
    if (mounted) setState(() => _waitedLong = false);
    _waitTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _waitedLong = true);
    });
  }

  void _step(int dir) {
    HapticFeedback.selectionClick();
    _remote.sendCommand(RemoteCommandType.reelStep, data: {'dir': dir});
  }

  void _deck(int dir) {
    HapticFeedback.selectionClick();
    _remote.sendCommand(RemoteCommandType.reelStep, data: {'deckDir': dir});
  }

  void _act(String action) {
    HapticFeedback.lightImpact();
    _remote.sendCommand(RemoteCommandType.reelAction, data: {'action': action});
  }

  @override
  Widget build(BuildContext context) {
    final tv = _remote.connectedDevice?.name ?? 'the TV';
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: _remote.reelState,
      builder: (context, state, _) {
        final deckName = state?['deckName'] as String?;
        return Scaffold(
          appBar: AppBar(
            title: Text(deckName ?? 'The Reel'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: StatChip(icon: Symbols.tv_rounded, label: 'On $tv'),
              ),
            ],
          ),
          body: state == null
              ? _Waiting(
                  long: _waitedLong,
                  tv: tv,
                  onRetry: () => _open(deck: widget.deck),
                )
              : _body(context, state),
        );
      },
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> state) {
    final theme = Theme.of(context);
    final card = (state['card'] as Map?)?.cast<String, dynamic>();
    final next = [
      for (final n in (state['next'] as List? ?? const []).whereType<Map>()) n.cast<String, dynamic>(),
    ].take(3).toList();
    final decks = [for (final d in (state['decks'] as List? ?? const []).whereType<Map>()) d.cast<String, dynamic>()];
    final playing = state['playing'] == true;
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            children: [
              for (final d in decks)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(d['name'] as String? ?? ''),
                    selected: d['id'] == state['deck'],
                    onSelected: (_) {
                      final id = d['id'];
                      if (id is String && id != state['deck']) _open(deck: id);
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              // The swipes live on the picture: the list itself scrolls on
              // a short screen (the Fold's cover), so it can't own them.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v.abs() > 250) _step(v < 0 ? 1 : -1);
                },
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v.abs() > 300) _deck(v < 0 ? 1 : -1);
                },
                onTap: () => _act('pause'),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (child, a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(
                      position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(a),
                      child: child,
                    ),
                  ),
                  child: _NowCard(
                    key: ValueKey(card?['id'] ?? state['poolEnd']),
                    card: card,
                    playing: playing,
                    poolEnd: state['poolEnd'] == true,
                  ),
                ),
              ),
              if (next.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Up next', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final n in next) _NextRow(card: n),
              ],
              const SizedBox(height: 12),
              Text(
                'Swipe the picture up for the next title, sideways for another deck. Tap it to pause.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: card == null ? null : () => _act('watch'),
                    icon: const Icon(Symbols.play_arrow_rounded),
                    label: const Text('Watch on TV'),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: card == null ? null : () => _act('save'),
                        icon: const Icon(Symbols.bookmark_add_rounded),
                        label: const Text('Save'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: card == null ? null : () => _act('notForMe'),
                        icon: const Icon(Symbols.do_not_disturb_on_rounded),
                        label: const Text('Not for me', maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: card == null ? null : () => _act('pause'),
                        icon: Icon(playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded),
                        label: Text(playing ? 'Pause' : 'Play'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NowCard extends StatelessWidget {
  const _NowCard({super.key, required this.card, required this.playing, required this.poolEnd});

  final Map<String, dynamic>? card;
  final bool playing;
  final bool poolEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = card;
    if (c == null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Card(
          margin: EdgeInsets.zero,
          child: Center(
            child: Text(
              poolEnd ? "That's the deck. Swipe sideways for another." : 'Nothing on this deck yet.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }
    final year = c['year'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Art(server: c['server'] as String?, path: (c['art'] ?? c['thumb']) as String?, width: 720),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: StatChip(
                    icon: playing ? Symbols.graphic_eq_rounded : Symbols.pause_rounded,
                    label: playing ? 'Playing on TV' : 'Paused',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          c['title'] as String? ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (year is int)
          Text('$year', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _NextRow extends StatelessWidget {
  const _NextRow({required this.card});

  final Map<String, dynamic> card;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 96,
            height: 54,
            child: _Art(server: card['server'] as String?, path: (card['art'] ?? card['thumb']) as String?, width: 96),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            card['title'] as String? ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      ],
    ),
  );
}

class _Art extends StatelessWidget {
  const _Art({required this.server, required this.path, required this.width});

  final String? server;
  final String? path;
  final double width;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: OptimizedMediaImage(
      client: context.tryGetMediaClientWithFallback(serverIdOrNull(server)),
      imagePath: path,
      width: width,
      height: width * 9 / 16,
      fit: BoxFit.cover,
      imageType: ImageType.art,
    ),
  );
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.long, required this.tv, required this.onRetry});

  final bool long;
  final String tv;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!long)
              const CircularProgressIndicator()
            else
              Icon(Symbols.tv_off_rounded, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              long ? "$tv isn't showing the Reel." : 'Opening the Reel on $tv…',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (long) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}
