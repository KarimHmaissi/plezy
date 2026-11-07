import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/device_performance.dart';
import '../../services/reel/reel_controller.dart';
import '../../theme/fork_motion.dart';
import '../../theme/fork_spacing.dart';
import '../../utils/layout_constants.dart';
import 'reel_card_view.dart' show ReelDeckStrip, ReelMessage;

/// The stuck-card watchdog's face ([ReelController.stuck]). A start or card
/// change that showed neither a first frame nor a still in about 8 s keeps
/// its card on screen as its art (the views drop their skeleton then) with
/// a notice over it and a retry: OK on the TV (↓ still goes on to the next
/// card), a tap on the phone. A deck that never loaded has no card to show,
/// so the notice stands in for the loading skeleton instead.
class ReelStuckLayer extends StatelessWidget {
  const ReelStuckLayer({super.key, required this.controller, required this.tv, required this.onRetry});

  final ReelController controller;
  final bool tv;

  /// Starts the Reel afresh (the screen's tab hide and show).
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ReelStuck?>(
    valueListenable: controller.stuck,
    builder: (context, stuck, _) {
      final reduce = ForkMotion.reduceMotion(context);
      final onCard = stuck != null && controller.current.kind == ReelSlotKind.card;
      final Widget child = stuck == null
          ? const SizedBox.shrink(key: ValueKey('reel-stuck:none'))
          : onCard
          ? _CardNotice(key: const ValueKey('reel-stuck:card'), tv: tv, onRetry: onRetry)
          : ReelMessage(
              key: const ValueKey('reel-stuck:deck'),
              icon: Symbols.hourglass_top_rounded,
              title: t.reel.status.stuckTitle,
              body: tv ? t.reel.status.stuckBodyTvLoading : t.reel.status.stuckBodyPhone,
              action: FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Symbols.refresh_rounded),
                label: Text(t.reel.card.tryAgain),
              ),
            );
      return AnimatedSwitcher(
        duration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetIn),
        reverseDuration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetOut),
        transitionBuilder: (child, animation) => onCard || stuck == null
            ? ForkMotion.riseTransition(animation, child)
            : FadeTransition(opacity: animation, child: child),
        layoutBuilder: (currentChild, previousChildren) =>
            Stack(fit: StackFit.expand, children: [...previousChildren, ?currentChild]),
        child: child,
      );
    },
  );
}

/// Over a stuck card: a pill at the top, in the deck strip's place and
/// style, saying it is taking a while and how to try again. On the phone
/// the whole pill is the retry.
class _CardNotice extends StatelessWidget {
  const _CardNotice({super.key, required this.tv, required this.onRetry});

  final bool tv;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = tv ? TvLayoutConstants.scaleOf(context) : 1.0;
    final size = MediaQuery.sizeOf(context);
    final scheme = theme.colorScheme;
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
      color: scheme.onSurface,
      fontSize: (theme.textTheme.titleSmall?.fontSize ?? 14) * scale,
      fontWeight: FontWeight.w700,
    );
    final bodyStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontSize: (theme.textTheme.bodySmall?.fontSize ?? 12) * scale,
    );
    final pill = Semantics(
      liveRegion: true,
      button: !tv,
      label: '${t.reel.status.stuckTitle}. ${tv ? t.reel.status.stuckBodyTv : t.reel.status.stuckBodyPhone}',
      excludeSemantics: true,
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: tv ? null : onRetry,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: 10 * scale),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Symbols.refresh_rounded, size: 22 * scale, color: scheme.primary),
                SizedBox(width: 12 * scale),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.reel.status.stuckTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                      Text(
                        tv ? t.reel.status.stuckBodyTv : t.reel.status.stuckBodyPhone,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: bodyStyle,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // TV: inside the overscan-safe margin, top left (the deck strip owns
    // the top right). Phone: under the top bar, centred.
    final edge = tv ? size.width * ReelDeckStrip.overscan : ForkSpacing.of(context).edgeInset;
    final top = tv ? size.height * ReelDeckStrip.overscan : MediaQuery.paddingOf(context).top + 64;
    return Padding(
      padding: EdgeInsets.fromLTRB(edge, top, edge, 0),
      child: Align(
        alignment: tv ? Alignment.topLeft : Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: tv ? size.width * 0.5 : 480),
          child: pill,
        ),
      ),
    );
  }
}
