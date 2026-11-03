import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy_brain/plezy_brain.dart' show TitleProfile;

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../services/ai/ai_week.dart';
import '../theme/fork_motion.dart';
import '../theme/fork_spacing.dart';
import '../theme/mono_tokens.dart';
import '../utils/media_image_helper.dart';
import '../utils/provider_extensions.dart';
import '../widgets/app_icon.dart';
import '../widgets/optimized_media_image.dart';
import '../widgets/pressable.dart';

/// Fork: "Your week in watching" at the top of the AI page: hours, films
/// and episodes, what was finished and started, a pattern, and the week's
/// posters. Counted on the device, so it costs nothing.
class AiWeekCard extends StatelessWidget {
  const AiWeekCard({super.key, required this.week, required this.items, required this.onItemTap, required this.onHide});

  final WatchWeek week;
  final List<MediaItem> items;
  final ValueChanged<MediaItem> onItemTap;
  final VoidCallback onHide;

  static const double _posterWidth = 76;

  static String _titles(List<TitleProfile> titles) => titles.take(3).map((p) => p.title).join(', ');

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    final spacing = ForkSpacing.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final dates = DateFormat.MMMd(locale);
    final last = week.end.subtract(const Duration(days: 1));
    final hours = (week.minutes / 60).round().clamp(1, 1 << 20);
    final counts = [
      if (week.films > 0) t.aiTab.weekFilms(n: week.films),
      if (week.episodes > 0) t.aiTab.weekEpisodes(n: week.episodes),
    ].join(' · ');
    final facts = <(IconData, String)>[
      if (week.finished.isNotEmpty)
        (Symbols.check_circle_rounded, t.aiTab.weekFinished(titles: _titles(week.finished))),
      if (week.started.isNotEmpty) (Symbols.play_circle_rounded, t.aiTab.weekStarted(titles: _titles(week.started))),
      if (week.bigNight case final day?)
        (
          Symbols.nightlife_rounded,
          // Any Monday-based date gives the weekday's name.
          t.aiTab.weekBigNight(day: DateFormat.EEEE(locale).format(DateTime(2024, 1, day))),
        )
      else if (week.topGenre case final genre?)
        (Symbols.theater_comedy_rounded, t.aiTab.weekMostly(genre: genre)),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(spacing.edgeInset, 0, spacing.edgeInset, spacing.rowGap),
      child: DecoratedBox(
        decoration: BoxDecoration(color: mono.surface, borderRadius: BorderRadius.circular(mono.radiusMd)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.aiTab.weekTitle, style: theme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                        Text(
                          t.aiTab.weekDates(from: dates.format(week.start), to: dates.format(last)),
                          style: theme.labelSmall?.copyWith(color: mono.textMuted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: t.aiTab.weekHide,
                    icon: AppIcon(Symbols.close_rounded, size: 20, color: mono.textMuted),
                    onPressed: () {
                      ForkMotion.selection();
                      onHide();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: t.aiTab.weekHours(n: hours),
                        style: theme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: mono.text),
                      ),
                      if (counts.isNotEmpty)
                        TextSpan(
                          text: '   $counts',
                          style: theme.bodyMedium?.copyWith(color: mono.textMuted),
                        ),
                    ],
                  ),
                ),
              ),
              for (final (icon, text) in facts)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppIcon(icon, size: 18, color: mono.textMuted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.bodyMedium?.copyWith(color: mono.text),
                        ),
                      ),
                    ],
                  ),
                ),
              if (items.isNotEmpty) ...[
                const SizedBox(height: 14),
                SizedBox(
                  height: _posterWidth * 1.5,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 12),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) => _Poster(item: items[i], onTap: () => onItemTap(items[i])),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.item, required this.onTap});

  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    const width = AiWeekCard._posterWidth, height = AiWeekCard._posterWidth * 1.5;
    return Pressable(
      longPress: false,
      borderRadius: BorderRadius.circular(mono.radiusSm),
      child: InkWell(
        borderRadius: BorderRadius.circular(mono.radiusSm),
        onTap: () {
          ForkMotion.selection();
          onTap();
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(mono.radiusSm),
          child: SizedBox(
            width: width,
            height: height,
            child: OptimizedMediaImage(
              client: context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId)),
              imagePath: item.thumbPath,
              width: width,
              height: height,
              imageType: ImageType.poster,
            ),
          ),
        ),
      ),
    );
  }
}
