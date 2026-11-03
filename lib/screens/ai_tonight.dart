import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../media/media_item.dart';
import '../services/ai/ai_briefing.dart';
import '../services/ai/ai_history.dart';
import '../services/settings_service.dart';
import '../theme/fork_spacing.dart';
import '../theme/mono_tokens.dart';
import '../widgets/ai_answer_card.dart' show withoutLeadingTitle;
import '../widgets/fork_motion_widgets.dart';
import '../widgets/media_card.dart';

/// Fork: "Tonight" at the top of the AI page on touch screens: up to three
/// wide cards (a new episode, tonight's pick, a library gem), each with its
/// label on the art and a one-line reason under the title. Cards tap and
/// long-press like any other.
class AiTonightBlock extends StatelessWidget {
  const AiTonightBlock({super.key, required this.entry, this.onItemTap});

  final AiHistoryEntry entry;
  final ValueChanged<MediaItem>? onItemTap;

  static String _label(String? slot) => switch (slot) {
    AiBriefing.slotNewEpisode => t.aiTab.tonightNewEpisode,
    AiBriefing.slotPick => t.aiTab.tonightPick,
    _ => t.aiTab.tonightLibrary,
  };

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    final spacing = ForkSpacing.of(context);
    final made = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(entry.createdAt),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: spacing.rowGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: spacing.edgeInset),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(t.aiTab.tonight, style: spacing.titleStyle(context)),
                const SizedBox(width: 10),
                Text(
                  t.aiTab.tonightUpdated(time: made),
                  style: theme.labelSmall?.copyWith(color: mono.textMuted),
                ),
              ],
            ),
          ),
          SizedBox(height: spacing.titleGap),
          LayoutBuilder(
            builder: (context, constraints) {
              // A little under the row's wide cards, so the next one peeks in.
              final width = (spacing.cardWidth(constraints.maxWidth, wide: true) * 1.1).clamp(220.0, 360.0);
              final artHeight = (width - 6) * 9 / 16;
              final height = artHeight + MediaCard.rowCaptionBandHeight(context) + 40;
              return SizedBox(
                height: height,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: spacing.edgeInset - 3),
                  itemCount: entry.items.length,
                  separatorBuilder: (_, _) => SizedBox(width: spacing.cardGap),
                  itemBuilder: (context, i) {
                    final item = entry.items[i];
                    final raw = entry.reasons[item.globalKey];
                    final reason = raw == null ? null : withoutLeadingTitle(raw, item.title);
                    // A new Tonight deals its cards in one after another.
                    return ForkEntrance(
                      key: ValueKey('${entry.createdAt.millisecondsSinceEpoch}-${item.globalKey}'),
                      index: i,
                      child: SizedBox(
                        width: width,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            MediaCard(
                              key: Key('tonight-${item.globalKey}'),
                              item: item,
                              width: width,
                              height: artHeight,
                              viewModeOverride: ViewMode.grid,
                              mixedHubContext: true,
                              episodePosterModeOverride: EpisodePosterMode.episodeThumbnail,
                              badges: [_label(entry.spotlights[item.globalKey])],
                              onTap: onItemTap == null ? null : () => onItemTap!(item),
                            ),
                            if (reason != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 3),
                                child: Text(
                                  reason,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.bodySmall?.copyWith(color: mono.textMuted, height: 1.35),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
