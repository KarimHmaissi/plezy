import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focus_theme.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../providers/companion_remote_provider.dart';
import '../../services/device_performance.dart';
import '../../services/reel/reel_art.dart';
import '../../theme/fork_motion.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/companion_remote/remote_button.dart';
import '../../widgets/optimized_media_image.dart';
import '../../widgets/stat_chip.dart';

/// Fork: the Fold's On TV mode. The TV's Reel plays; the phone shows its
/// card and the next three and sends `reelStep` / `reelAction`. The phone
/// plays nothing. A full remote (V2-49): previous and next, play and pause,
/// the TV's Reel volume, and a More menu with the TV sheet's card actions.
/// Built from the app's own theme and widgets.
class ReelRemoteView extends StatefulWidget {
  const ReelRemoteView({super.key, this.deck, this.groupKey});

  /// The deck the phone was on, opened on the TV.
  final String? deck;

  /// The title the phone was on (its `groupKey`): the TV opens [deck] on
  /// it when its own list of the deck has it, else on the deck's cursor.
  final String? groupKey;

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
    _open(deck: widget.deck, groupKey: widget.groupKey);
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    super.dispose();
  }

  void _open({String? deck, String? groupKey}) {
    _remote.sendCommand(RemoteCommandType.tabReel);
    _remote.sendCommand(RemoteCommandType.reelOpen, data: {'deck': ?deck, 'groupKey': ?groupKey});
    _waitTimer?.cancel();
    if (mounted) setState(() => _waitedLong = false);
    _waitTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _waitedLong = true);
    });
  }

  /// [haptic]: false from a [RemoteButton], which gives its own.
  void _step(int dir, {bool haptic = true}) {
    if (haptic) ForkMotion.selection();
    _remote.sendCommand(RemoteCommandType.reelStep, data: {'dir': dir});
  }

  void _deck(int dir) {
    ForkMotion.selection();
    _remote.sendCommand(RemoteCommandType.reelStep, data: {'deckDir': dir});
  }

  /// Save confirms like any save in the app; the rest tick like a toggle.
  /// [haptic]: false from a [RemoteButton], which gives its own.
  void _act(String action, {bool haptic = true}) {
    if (haptic && action == 'save') {
      ForkMotion.success();
    } else if (haptic) {
      ForkMotion.selection();
    }
    _remote.sendCommand(RemoteCommandType.reelAction, data: {'action': action});
  }

  /// The TV sheet's card actions: Details, Seen it, and with a clip on
  /// the card, Spoiled me and Replay.
  Future<void> _more(Map<String, dynamic> card, {required bool hasClip}) async {
    final picked = await showAdaptiveAppMenu<String>(
      context,
      title: card['title'] as String?,
      entries: [
        AppMenuItem(value: 'details', icon: Symbols.info_rounded, label: t.reel.sheet.details),
        AppMenuItem(value: 'seenIt', icon: Symbols.check_rounded, label: t.reel.sheet.seenIt),
        if (hasClip) ...[
          AppMenuItem(value: 'spoiled', icon: Symbols.visibility_off_rounded, label: t.reel.sheet.spoiledMe),
          AppMenuItem(value: 'replay', icon: Symbols.replay_rounded, label: t.reel.card.replay),
        ],
      ],
    );
    if (picked != null && mounted) _act(picked);
  }

  @override
  Widget build(BuildContext context) {
    final tv = _remote.connectedDevice?.name ?? t.reel.remote.theTv;
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: _remote.reelState,
      builder: (context, state, _) {
        final deckName = state?['deckName'] as String?;
        return Scaffold(
          appBar: AppBar(
            title: Text(deckName ?? t.reel.remote.title),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: StatChip(
                  icon: Symbols.tv_rounded,
                  label: t.reel.remote.onTv(tv: tv),
                ),
              ),
            ],
          ),
          body: state == null
              ? _Waiting(
                  long: _waitedLong,
                  tv: tv,
                  onRetry: () => _open(deck: widget.deck, groupKey: widget.groupKey),
                )
              : _body(context, state),
        );
      },
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> state) {
    final theme = Theme.of(context);
    final card = (state['card'] as Map?)?.cast<String, dynamic>();
    // Tonight's picks (V2-38) on the TV: its posters, tap one to choose it.
    final decide = (state['decide'] as Map?)?.cast<String, dynamic>();
    // A deck's intro card (D22) on the TV: its line.
    final intro = (state['intro'] as Map?)?['line'];
    final next = [
      for (final n in (state['next'] as List? ?? const []).whereType<Map>()) n.cast<String, dynamic>(),
    ].take(3).toList();
    final decks = [for (final d in (state['decks'] as List? ?? const []).whereType<Map>()) d.cast<String, dynamic>()];
    final playing = state['playing'] == true;
    final hasClip = state['hasClip'] == true;
    final muted = state['muted'] == true;
    final remote = t.companionRemote.remote;
    return Column(
      children: [
        // Scrolls sideways and takes the chips' own height, so large text
        // never clips them.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
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
                  duration: ForkMotion.reduceMotion(context)
                      ? Duration.zero
                      : DevicePerformance.reducedDuration(const Duration(milliseconds: 280)),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (child, a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(
                      position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(a),
                      child: child,
                    ),
                  ),
                  child: decide != null
                      ? _DecideCard(key: const ValueKey('decide'), decide: decide, onPick: (i) => _act('pick:$i'))
                      : _NowCard(
                          key: ValueKey(card?['id'] ?? (intro is String ? 'intro' : state['poolEnd'])),
                          card: card,
                          playing: playing,
                          poolEnd: state['poolEnd'] == true,
                          intro: intro is String ? intro : null,
                        ),
                ),
              ),
              const SizedBox(height: 20),
              _ButtonRow(
                children: [
                  RemoteButton(
                    icon: Symbols.skip_previous_rounded,
                    label: remote.previous,
                    onPressed: () => _step(-1, haptic: false),
                  ),
                  RemoteButton(
                    icon: playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                    label: playing ? t.reel.remote.pause : t.reel.remote.play,
                    size: 64,
                    iconSize: 36,
                    onPressed: card == null ? null : () => _act('pause', haptic: false),
                  ),
                  RemoteButton(
                    icon: Symbols.skip_next_rounded,
                    label: remote.next,
                    onPressed: () => _step(1, haptic: false),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(remote.volume, textAlign: TextAlign.center, style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              _ButtonRow(
                children: [
                  RemoteButton(
                    icon: muted ? Symbols.volume_up_rounded : Symbols.volume_off_rounded,
                    label: muted ? t.reel.card.soundOn : t.reel.card.mute,
                    onPressed: () => _act('mute', haptic: false),
                  ),
                  RemoteButton(
                    icon: Symbols.volume_down_rounded,
                    label: remote.volumeDown,
                    onPressed: () => _act('volumeDown', haptic: false),
                  ),
                  RemoteButton(
                    icon: Symbols.volume_up_rounded,
                    label: remote.volumeUp,
                    onPressed: () => _act('volumeUp', haptic: false),
                  ),
                ],
              ),
              if (next.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(t.reel.remote.upNext, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final n in next) _NextRow(card: n),
              ],
              const SizedBox(height: 12),
              Text(
                t.reel.remote.howTo,
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
                    onPressed: card == null && decide == null ? null : () => _act('watch'),
                    icon: const Icon(Symbols.play_arrow_rounded),
                    label: Text(t.reel.remote.watchOnTv),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: card == null ? null : () => _act('save'),
                        icon: const Icon(Symbols.bookmark_add_rounded),
                        label: Text(t.reel.remote.save),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: card == null ? null : () => _act('notForMe'),
                        icon: const Icon(Symbols.do_not_disturb_on_rounded),
                        label: Text(t.reel.remote.notForMe, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: card == null ? null : () => unawaited(_more(card, hasClip: hasClip)),
                        icon: const Icon(Symbols.more_horiz_rounded),
                        label: Text(t.reel.card.more, maxLines: 1, overflow: TextOverflow.ellipsis),
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

/// Three remote buttons spaced across the width, as on the phone remote;
/// they wrap rather than overflow at large text.
class _ButtonRow extends StatelessWidget {
  const _ButtonRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      Wrap(alignment: WrapAlignment.spaceEvenly, spacing: 16, runSpacing: 12, children: children);
}

class _NowCard extends StatelessWidget {
  const _NowCard({super.key, required this.card, required this.playing, required this.poolEnd, this.intro});

  final Map<String, dynamic>? card;
  final bool playing;
  final bool poolEnd;

  /// The TV shows the deck's intro card: its line.
  final String? intro;

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
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                intro ?? (poolEnd ? t.reel.remote.deckEnd : t.reel.remote.deckEmpty),
                textAlign: TextAlign.center,
                style: intro != null
                    ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)
                    : theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
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
                _Art(server: c['server'] as String?, path: (c['art'] ?? c['thumb']) as String?),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: StatChip(
                    icon: playing ? Symbols.graphic_eq_rounded : Symbols.pause_rounded,
                    label: playing ? t.reel.remote.playingOnTv : t.reel.remote.paused,
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

/// Tonight's picks as the TV shows it: the posters, the chosen one ringed.
class _DecideCard extends StatelessWidget {
  const _DecideCard({super.key, required this.decide, required this.onPick});

  final Map<String, dynamic> decide;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picks = [for (final p in (decide['picks'] as List? ?? const []).whereType<Map>()) p.cast<String, dynamic>()];
    final chosen = decide['pick'] is int ? decide['pick'] as int : 0;
    final title = chosen >= 0 && chosen < picks.length ? picks[chosen]['title'] as String? : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StatChip(icon: Symbols.bookmarks_rounded, label: t.reel.decide.title),
        const SizedBox(height: 8),
        Text(t.reel.decide.prompt, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final (i, p) in picks.indexed) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(
                child: Semantics(
                  button: true,
                  selected: i == chosen,
                  label: p['title'] as String? ?? '',
                  child: GestureDetector(
                    onTap: () => onPick(i),
                    child: Container(
                      foregroundDecoration: FocusTheme.focusDecoration(
                        context,
                        isFocused: i == chosen,
                        borderStrokeAlign: BorderSide.strokeAlignOutside,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(FocusTheme.defaultBorderRadius),
                        child: AspectRatio(
                          aspectRatio: 2 / 3,
                          child: _Art(
                            server: p['server'] as String?,
                            path: (p['thumb'] ?? p['art']) as String?,
                            imageType: ImageType.poster,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            // Fewer than three keep their size.
            for (var i = picks.length; i < 3; i++) ...[const SizedBox(width: 10), const Expanded(child: SizedBox())],
          ],
        ),
        if (title != null) ...[
          const SizedBox(height: 12),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
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

/// Art decoded at the size it is shown (plan V2-05): at [width] when the
/// tile is a fixed size, else at the frame it fills. Tracked as the Reel's,
/// so the art budget and suspend let it go.
class _Art extends StatelessWidget {
  const _Art({required this.server, required this.path, this.width, this.imageType = ImageType.art});

  final String? server;
  final String? path;
  final double? width;
  final ImageType imageType;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: OptimizedMediaImage(
      client: context.tryGetMediaClientWithFallback(serverIdOrNull(server)),
      imagePath: path,
      width: width,
      height: switch (width) {
        null => null,
        final w => imageType == ImageType.poster ? w * 3 / 2 : w * 9 / 16,
      },
      fit: BoxFit.cover,
      imageType: imageType,
      onImageProvider: ReelArt.track,
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
              long ? t.reel.remote.notShowing(tv: tv) : t.reel.remote.opening(tv: tv),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (long) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: Text(t.reel.remote.tryAgain)),
            ],
          ],
        ),
      ),
    );
  }
}
