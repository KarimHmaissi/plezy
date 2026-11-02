import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../services/ai/ai_history.dart';
import '../services/settings_service.dart';
import '../theme/fork_motion.dart';
import '../theme/fork_spacing.dart';
import '../theme/mono_tokens.dart';
import '../utils/media_image_helper.dart';
import '../utils/provider_extensions.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_menu.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/media_card.dart';
import '../widgets/media_card_sliver_layout.dart';
import '../widgets/media_context_menu.dart' show MediaMenuExtraEntry;
import '../widgets/optimized_media_image.dart';
import '../widgets/pressable.dart';
import '../widgets/settings_builder.dart';
import '../widgets/system_bottom_inset.dart';

/// Fork: an AI answer laid out as a page, opened from its row's answer
/// tile on touch screens: what was asked and the headline, the overview,
/// the top picks and the ones worth a closer look (poster, title, why), the
/// notes, the follow-ups, then every pick as a grid. The row's actions sit
/// in the app bar's ⋯.
class AiAnswerPage extends StatelessWidget {
  const AiAnswerPage({
    super.key,
    required this.entry,
    required this.onPick,
    this.onFollowUp,
    this.rowEntries = const [],
    this.badgesFor,
    this.linkify,
  });

  final AiHistoryEntry entry;
  final ValueChanged<MediaItem> onPick;

  /// Runs the follow-up as a new request; the page closes first.
  final ValueChanged<String>? onFollowUp;
  final List<MediaMenuExtraEntry> rowEntries;
  final List<String> Function(MediaItem item)? badgesFor;
  final List<InlineSpan> Function(String text, TextStyle? style)? linkify;

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    final spacing = ForkSpacing.of(context);
    final overview = (entry.cardText ?? '').trim();
    final headline = entry.headline?.trim();
    final overviewStyle = theme.bodyLarge?.copyWith(height: 1.55, color: mono.text);

    List<(MediaItem, String)> noted(Map<String, String> notes) => [
      for (final item in entry.items)
        if (notes[item.globalKey] case final text?) (item, text),
    ];
    final topPicks = noted(entry.topPicks);
    final spotlights = noted(entry.spotlights);

    Widget section(String title, List<Widget> children) => Padding(
      padding: EdgeInsets.only(top: spacing.rowGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: spacing.titleStyle(context)),
          SizedBox(height: spacing.titleGap),
          ...children,
        ],
      ),
    );

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          DesktopSliverAppBar(
            title: Text(entry.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            pinned: false,
            floating: true,
            snap: true,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
            actions: [
              if (rowEntries.isNotEmpty)
                IconButton(
                  tooltip: t.aiTab.more,
                  icon: const AppIcon(Symbols.more_horiz_rounded, fill: 1),
                  onPressed: () async {
                    final picked = await showAdaptiveAppMenu<int>(
                      context,
                      title: entry.label,
                      entries: [
                        for (final (i, e) in rowEntries.indexed) AppMenuItem(value: i, icon: e.icon, label: e.label),
                      ],
                    );
                    if (picked == null || picked >= rowEntries.length || !context.mounted) return;
                    rowEntries[picked].onSelected();
                  },
                ),
            ],
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: spacing.edgeInset),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.aiTab.askedLabel, style: theme.labelMedium?.copyWith(color: mono.textMuted)),
                  const SizedBox(height: 2),
                  Text(entry.request, style: theme.bodyMedium?.copyWith(color: mono.textMuted, height: 1.4)),
                  if (headline != null && headline.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      headline,
                      style: theme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.25, color: mono.text),
                    ),
                  ],
                  if (overview.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text.rich(
                      TextSpan(children: linkify?.call(overview, overviewStyle) ?? [TextSpan(text: overview)]),
                      style: overviewStyle,
                    ),
                  ],
                  if (topPicks.isNotEmpty)
                    section(t.aiTab.topPicks, [
                      for (final (item, text) in topPicks)
                        _PickNote(item: item, text: text, onTap: onPick, large: true),
                    ]),
                  if (spotlights.isNotEmpty)
                    section(t.aiTab.spotlight, [
                      for (final (item, text) in spotlights) _PickNote(item: item, text: text, onTap: onPick),
                    ]),
                  if (entry.notes.isNotEmpty) ...[
                    SizedBox(height: spacing.rowGap),
                    for (final n in entry.notes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: AppIcon(Symbols.info_rounded, size: 16, color: mono.textMuted),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(n, style: theme.bodyMedium?.copyWith(color: mono.textMuted, height: 1.45)),
                            ),
                          ],
                        ),
                      ),
                  ],
                  if (entry.followUps.isNotEmpty && onFollowUp != null) ...[
                    SizedBox(height: spacing.rowGap - 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final f in entry.followUps)
                          ActionChip(
                            label: Text(f),
                            labelStyle: theme.labelLarge,
                            onPressed: () {
                              ForkMotion.selection();
                              Navigator.of(context).pop();
                              onFollowUp!(f);
                            },
                          ),
                      ],
                    ),
                  ],
                  if (entry.items.isNotEmpty) ...[
                    SizedBox(height: spacing.rowGap),
                    Text(t.aiTab.allPicks, style: spacing.titleStyle(context)),
                  ],
                ],
              ),
            ),
          ),
          if (entry.items.isNotEmpty)
            SettingsBuilder(
              prefs: const [SettingsService.libraryDensity],
              builder: (context) => MediaCardSliverLayout(
                viewMode: ViewMode.grid,
                itemCount: entry.items.length,
                density: SettingsService.instance.read(SettingsService.libraryDensity),
                padding: EdgeInsets.fromLTRB(spacing.edgeInset - 4, spacing.titleGap, spacing.edgeInset - 4, 0),
                itemBuilder: (context, position) {
                  final item = entry.items[position.index];
                  return MediaCard(
                    key: Key(item.globalKey),
                    item: item,
                    onTap: () => onPick(item),
                    viewModeOverride: ViewMode.grid,
                    badges: badgesFor?.call(item) ?? const [],
                  );
                },
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          const SliverSystemBottomInset(),
        ],
      ),
    );
  }
}

/// A pick with its poster, title, year and what the answer says about it.
class _PickNote extends StatelessWidget {
  const _PickNote({required this.item, required this.text, required this.onTap, this.large = false});

  final MediaItem item;
  final String text;
  final ValueChanged<MediaItem> onTap;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    final width = large ? 72.0 : 56.0;
    final meta = [
      if (item.year != null) '${item.year}',
      if (item.kind == MediaKind.show)
        t.common.mediaKind.show
      else if (item.kind == MediaKind.movie)
        t.common.mediaKind.movie,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Pressable(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            ForkMotion.selection();
            onTap(item);
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(mono.radiusSm),
                child: OptimizedMediaImage(
                  client: context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId)),
                  imagePath: item.posterThumb(),
                  width: width,
                  height: width * 1.5,
                  imageType: ImageType.poster,
                  fallbackIcon: Symbols.movie_rounded,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title ?? '',
                      style: (large ? theme.titleMedium : theme.titleSmall)?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: mono.text,
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(meta, style: theme.bodySmall?.copyWith(color: mono.textMuted)),
                      ),
                    const SizedBox(height: 6),
                    Text(text, style: theme.bodyMedium?.copyWith(height: 1.45, color: mono.textMuted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
