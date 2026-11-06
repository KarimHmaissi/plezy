import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../media/ids.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../providers/companion_remote_provider.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/optimized_media_image.dart';
import 'reel_card_view.dart';

/// Fork: the Fold's On TV mode. The TV's Reel plays; the phone shows its
/// card and the next three and sends `reelStep` / `reelAction`. The phone
/// plays nothing.
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
    setState(() => _waitedLong = false);
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
    return Scaffold(
      backgroundColor: ReelInk.booth,
      body: SafeArea(
        child: ValueListenableBuilder<Map<String, dynamic>?>(
          valueListenable: _remote.reelState,
          builder: (context, state, _) {
            final header = _Header(tv: tv, deckName: state?['deckName'] as String?);
            if (state == null) {
              return Column(
                children: [
                  header,
                  Expanded(
                    child: _Waiting(
                      long: _waitedLong,
                      tv: tv,
                      onRetry: () => _open(deck: widget.deck),
                    ),
                  ),
                ],
              );
            }
            final card = (state['card'] as Map?)?.cast<String, dynamic>();
            final next = [
              for (final n in (state['next'] as List? ?? const []).whereType<Map>()) n.cast<String, dynamic>(),
            ].take(3).toList();
            final decks = [
              for (final d in (state['decks'] as List? ?? const []).whereType<Map>()) d.cast<String, dynamic>(),
            ];
            final playing = state['playing'] == true;
            return Column(
              children: [
                header,
                _DeckChips(
                  decks: decks,
                  current: state['deck'] as String?,
                  onOpen: (id) => _open(deck: id),
                ),
                Expanded(
                  child: GestureDetector(
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
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 12),
                          AnimatedSwitcher(
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
                          const SizedBox(height: 18),
                          if (next.isNotEmpty) ...[
                            const Text(
                              'UP NEXT',
                              style: TextStyle(
                                color: ReelInk.dim,
                                fontSize: 11,
                                letterSpacing: 2.4,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            for (final (i, n) in next.indexed) _NextRow(card: n, delay: i),
                          ],
                          const Spacer(),
                          const Center(
                            child: Text(
                              'Swipe up for the next title · sideways for another deck',
                              style: TextStyle(color: ReelInk.dim, fontSize: 12),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                ),
                _Controls(
                  playing: playing,
                  hasCard: card != null,
                  onWatch: () => _act('watch'),
                  onSave: () => _act('save'),
                  onNotForMe: () => _act('notForMe'),
                  onPause: () => _act('pause'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.tv, this.deckName});

  final String tv;
  final String? deckName;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
    child: Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded, color: ReelInk.paper),
          tooltip: 'Back',
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: ReelInk.lamp, borderRadius: BorderRadius.circular(4)),
          child: const Text(
            'ON TV',
            style: TextStyle(color: ReelInk.booth, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            deckName == null ? tv : '$deckName  ·  $tv',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: ReelInk.paper, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _DeckChips extends StatelessWidget {
  const _DeckChips({required this.decks, required this.current, required this.onOpen});

  final List<Map<String, dynamic>> decks;
  final String? current;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      children: [
        for (final d in decks)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(d['name'] as String? ?? ''),
              selected: d['id'] == current,
              showCheckmark: false,
              selectedColor: ReelInk.lamp,
              backgroundColor: const Color(0x22F6F1E7),
              side: BorderSide.none,
              labelStyle: TextStyle(
                color: d['id'] == current ? ReelInk.booth : ReelInk.paper,
                fontWeight: FontWeight.w700,
              ),
              onSelected: (_) {
                final id = d['id'];
                if (id is String && id != current) onOpen(id);
              },
            ),
          ),
      ],
    ),
  );
}

class _NowCard extends StatelessWidget {
  const _NowCard({super.key, required this.card, required this.playing, required this.poolEnd});

  final Map<String, dynamic>? card;
  final bool playing;
  final bool poolEnd;

  @override
  Widget build(BuildContext context) {
    final c = card;
    if (c == null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: DecoratedBox(
          decoration: BoxDecoration(color: const Color(0x14F6F1E7), borderRadius: BorderRadius.circular(10)),
          child: Center(
            child: Text(
              poolEnd ? "That's the deck. Swipe sideways for another." : 'Nothing on this deck yet.',
              style: const TextStyle(color: ReelInk.dim),
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
          borderRadius: BorderRadius.circular(10),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Art(server: c['server'] as String?, path: (c['art'] ?? c['thumb']) as String?, width: 720),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: playing ? ReelInk.lamp : const Color(0xCC0B0A09),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          playing ? Icons.graphic_eq_rounded : Icons.pause_rounded,
                          size: 14,
                          color: playing ? ReelInk.booth : ReelInk.paper,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          playing ? 'PLAYING ON TV' : 'PAUSED',
                          style: TextStyle(
                            color: playing ? ReelInk.booth : ReelInk.paper,
                            fontSize: 10,
                            letterSpacing: 1.6,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
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
          style: const TextStyle(color: ReelInk.paper, fontSize: 24, fontWeight: FontWeight.w800, height: 1.1),
        ),
        if (year is int) Text('$year', style: const TextStyle(color: ReelInk.dim)),
      ],
    );
  }
}

class _NextRow extends StatelessWidget {
  const _NextRow({required this.card, required this.delay});

  final Map<String, dynamic> card;
  final int delay;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    key: ValueKey(card['id']),
    tween: Tween(begin: 0, end: 1),
    duration: Duration(milliseconds: 260 + delay * 80),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, (1 - t) * 10), child: child),
    ),
    child: Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 96,
              height: 54,
              child: _Art(
                server: card['server'] as String?,
                path: (card['art'] ?? card['thumb']) as String?,
                width: 240,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              card['title'] as String? ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: ReelInk.paper, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
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
    color: const Color(0x14F6F1E7),
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

class _Controls extends StatelessWidget {
  const _Controls({
    required this.playing,
    required this.hasCard,
    required this.onWatch,
    required this.onSave,
    required this.onNotForMe,
    required this.onPause,
  });

  final bool playing;
  final bool hasCard;
  final VoidCallback onWatch;
  final VoidCallback onSave;
  final VoidCallback onNotForMe;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x000B0A09), Color(0xFF15120E)],
      ),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: hasCard ? onWatch : null,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Watch on TV'),
            style: FilledButton.styleFrom(
              backgroundColor: ReelInk.lamp,
              foregroundColor: ReelInk.booth,
              padding: const EdgeInsets.symmetric(vertical: 14),
              textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              shape: const StadiumBorder(),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _Small(icon: Icons.bookmark_add_outlined, label: 'Save', onTap: hasCard ? onSave : null),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Small(
                icon: Icons.do_not_disturb_on_outlined,
                label: 'Not for me',
                onTap: hasCard ? onNotForMe : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Small(
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                label: playing ? 'Pause' : 'Play',
                onTap: hasCard ? onPause : null,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _Small extends StatelessWidget {
  const _Small({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon, size: 18),
    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    style: OutlinedButton.styleFrom(
      foregroundColor: ReelInk.paper,
      side: const BorderSide(color: Color(0x44F6F1E7)),
      padding: const EdgeInsets.symmetric(vertical: 12),
      shape: const StadiumBorder(),
    ),
  );
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.long, required this.tv, required this.onRetry});

  final bool long;
  final String tv;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!long) const CircularProgressIndicator(color: ReelInk.lamp, strokeWidth: 2),
          const SizedBox(height: 18),
          Text(
            long ? "$tv isn't showing the Reel." : 'Opening the Reel on $tv…',
            textAlign: TextAlign.center,
            style: const TextStyle(color: ReelInk.paper, fontSize: 16),
          ),
          if (long) ...[
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: ReelInk.lamp,
                side: const BorderSide(color: ReelInk.lamp),
              ),
              child: const Text('Try again'),
            ),
          ],
        ],
      ),
    ),
  );
}
