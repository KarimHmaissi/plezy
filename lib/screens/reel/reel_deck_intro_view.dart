import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focus_theme.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../services/reel/reel_art.dart';
import '../../services/reel/reel_controller.dart';
import '../../utils/layout_constants.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/fork_motion_widgets.dart';
import '../../widgets/optimized_media_image.dart';
import '../../widgets/stat_chip.dart';
import 'reel_sheet.dart' show reelDeckIcon;

/// A deck's intro card (D22, build plan §4 card kind 3): the deck's name,
/// its one computed line ("12 films, 4 shows arrived. 3 worth a look.") and
/// its first cards as a poster strip. Nothing plays on it.
///
/// A poster shows only when the Reel already has that card's metadata (the
/// first card and the next, which the window reads anyway); the others
/// show their title, so the intro never reads a server of its own (D15).
///
/// TV: OK or ↓ goes to the first card (ReelScreen's keys). Phone: Start, or
/// a swipe up.
class ReelDeckIntroView extends StatelessWidget {
  const ReelDeckIntroView({
    super.key,
    required this.deckId,
    required this.deckName,
    required this.slot,
    required this.tv,
    this.onStart,
  });

  final String deckId;
  final String deckName;
  final ReelSlot slot;
  final bool tv;

  /// Phone: Start goes to the first card.
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = tv ? TvLayoutConstants.scaleOf(context) : 1.0;
    final line = slot.intro?.line ?? '';
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: tv ? TvLayoutConstants.horizontalInset : 20, vertical: 24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final n = slot.previews.length;
                final gap = (tv ? 20 : 10) * scale;
                // At most five across; on the phone never wider than the screen.
                final across = n == 0 ? 1 : n;
                final width = tv
                    ? 124 * scale
                    : ((constraints.maxWidth - gap * (across - 1)) / across).clamp(48.0, 104.0);
                final height = width * 3 / 2;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ForkEntrance(
                      child: StatChip(icon: reelDeckIcon(deckId), label: deckName),
                    ),
                    SizedBox(height: 14 * scale),
                    ForkEntrance(
                      index: 1,
                      child: Text(
                        line,
                        key: const ValueKey('reel-intro-line'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: (theme.textTheme.headlineSmall?.fontSize ?? 24) * scale,
                        ),
                      ),
                    ),
                    if (n > 0) ...[
                      SizedBox(height: 24 * scale),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (i, p) in slot.previews.indexed) ...[
                            if (i > 0) SizedBox(width: gap),
                            ForkEntrance(
                              key: ValueKey('reel-intro:${p.card.id}'),
                              index: i + 2,
                              child: _Poster(preview: p, width: width, height: height),
                            ),
                          ],
                        ],
                      ),
                    ],
                    SizedBox(height: 24 * scale),
                    if (tv)
                      Text(
                        t.reel.deckIntro.hintTv,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 14 * scale,
                        ),
                      )
                    else ...[
                      FilledButton.icon(
                        onPressed: onStart,
                        icon: const Icon(Symbols.play_arrow_rounded, fill: 1),
                        label: Text(t.reel.deckIntro.start),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        t.reel.deckIntro.swipe,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// One of the deck's first cards: its poster when the Reel has the card's
/// metadata, else its title.
class _Poster extends StatelessWidget {
  const _Poster({required this.preview, required this.width, required this.height});

  final ReelIntroPreview preview;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = preview.card;
    final item = preview.item;
    final fallback = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Text(
            card.title.title,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ),
    );
    return Semantics(
      label: card.title.title,
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(FocusTheme.defaultBorderRadius),
        child: SizedBox(
          width: width,
          height: height,
          child: item?.thumbPath == null
              ? fallback
              : OptimizedMediaImage(
                  client: context.tryGetMediaClientWithFallback(serverIdOrNull(card.best.serverId)),
                  imagePath: item!.thumbPath,
                  width: width,
                  height: height,
                  fit: BoxFit.cover,
                  imageType: ImageType.poster,
                  // The Reel's art: the budget and suspend let it go.
                  onImageProvider: ReelArt.track,
                  placeholder: (_, _) => fallback,
                  errorWidget: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}
