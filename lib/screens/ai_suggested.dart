import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../services/ai/ai_suggestions.dart';
import '../theme/fork_motion.dart';
import '../theme/fork_spacing.dart';
import '../theme/mono_tokens.dart';
import '../utils/media_image_helper.dart';
import '../utils/provider_extensions.dart';
import '../widgets/app_icon.dart';
import '../widgets/fork_motion_widgets.dart';
import '../widgets/optimized_media_image.dart';
import '../widgets/pressable.dart';

/// Fork: "Suggested for you" on the AI page: one row of ready-made lists
/// (three posters and a name each), ending in a "New lists" tile. Kept apart
/// from the user's own answers so those never fill up with the AI's ideas.
class AiSuggestedShelf extends StatelessWidget {
  const AiSuggestedShelf({
    super.key,
    required this.lists,
    required this.onOpen,
    required this.onNewLists,
    this.making = false,
  });

  final List<AiSuggestion> lists;
  final ValueChanged<AiSuggestion> onOpen;
  final VoidCallback? onNewLists;

  /// A new set is being made: the New lists tile says so.
  final bool making;

  static const double _tileWidth = 172;
  static const double _posterGap = 3;

  @override
  Widget build(BuildContext context) {
    final spacing = ForkSpacing.of(context);
    final posterHeight = (_tileWidth - 2 * _posterGap) / 3 * 1.5;
    return Padding(
      padding: EdgeInsets.only(bottom: spacing.rowGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: spacing.edgeInset),
            child: Text(t.aiTab.suggestedTitle, style: spacing.titleStyle(context)),
          ),
          SizedBox(height: spacing.titleGap),
          SizedBox(
            height: posterHeight + 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: spacing.edgeInset),
              itemCount: lists.length + 1,
              separatorBuilder: (_, _) => SizedBox(width: spacing.cardGap + 4),
              itemBuilder: (context, i) {
                if (i == lists.length) {
                  return _NewListsTile(height: posterHeight, making: making, onTap: onNewLists);
                }
                final list = lists[i];
                return ForkEntrance(
                  key: ValueKey('suggested-${list.entry.id}'),
                  index: i,
                  child: _ListTile(list: list, posterHeight: posterHeight, onTap: () => onOpen(list)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ListTile extends StatelessWidget {
  const _ListTile({required this.list, required this.posterHeight, required this.onTap});

  final AiSuggestion list;
  final double posterHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    final posters = list.entry.items.take(3).toList();
    final posterWidth = (AiSuggestedShelf._tileWidth - 2 * AiSuggestedShelf._posterGap) / 3;
    return SizedBox(
      width: AiSuggestedShelf._tileWidth,
      child: Pressable(
        longPress: false,
        borderRadius: BorderRadius.circular(mono.radiusSm),
        child: InkWell(
          borderRadius: BorderRadius.circular(mono.radiusSm),
          onTap: () {
            ForkMotion.selection();
            onTap();
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(mono.radiusSm),
                child: Row(
                  children: [
                    for (final (n, item) in posters.indexed) ...[
                      if (n > 0) const SizedBox(width: AiSuggestedShelf._posterGap),
                      _Poster(item: item, width: posterWidth, height: posterHeight),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                list.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.titleSmall?.copyWith(fontWeight: FontWeight.w600, height: 1.25),
              ),
              const SizedBox(height: 2),
              Text(
                t.aiTab.picksCount(count: list.entry.items.length),
                style: theme.labelSmall?.copyWith(color: mono.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.item, required this.width, required this.height});

  final MediaItem item;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(
        color: tokens(context).surface,
        child: OptimizedMediaImage(
          client: context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId)),
          imagePath: item.thumbPath,
          width: width,
          height: height,
          imageType: ImageType.poster,
        ),
      ),
    );
  }
}

class _NewListsTile extends StatelessWidget {
  const _NewListsTile({required this.height, required this.making, required this.onTap});

  final double height;
  final bool making;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    return SizedBox(
      width: 112,
      height: height,
      child: Pressable(
        longPress: false,
        enabled: !making && onTap != null,
        borderRadius: BorderRadius.circular(mono.radiusSm),
        child: Material(
          color: mono.surface,
          borderRadius: BorderRadius.circular(mono.radiusSm),
          child: InkWell(
            borderRadius: BorderRadius.circular(mono.radiusSm),
            onTap: making || onTap == null
                ? null
                : () {
                    ForkMotion.selection();
                    onTap!();
                  },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (making)
                  SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: mono.textMuted),
                  )
                else
                  AppIcon(Symbols.auto_awesome_rounded, fill: 1, size: 24, color: mono.text),
                const SizedBox(height: 10),
                Text(
                  making ? t.aiTab.makingLists : t.aiTab.newLists,
                  textAlign: TextAlign.center,
                  style: theme.labelMedium?.copyWith(color: mono.text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
