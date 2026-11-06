import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../focus/focus_theme.dart';
import '../../media/ids.dart';
import '../../services/reel/reel_controller.dart';
import '../../theme/fork_motion.dart';
import '../../utils/layout_constants.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/fork_motion_widgets.dart';
import '../../widgets/optimized_media_image.dart';
import '../../widgets/stat_chip.dart';
import '../../widgets/tv_spotlight_background.dart';
import 'reel_card_view.dart';

/// Tonight's picks (V2-38): the Reel's one decision card. It closes the
/// loop on the scrolling: the titles saved lately as posters, one chosen,
/// and Watch. It comes up at most once a session (after the second Save,
/// or at the end of a deck), with no counts and no streaks.
///
/// TV: Home's spotlight for the chosen pick, the posters underneath; D-pad
/// left and right choose, OK watches (ReelScreen's keys). Phone: tap a
/// poster to choose it, then Watch.
class ReelDecideView extends StatelessWidget {
  const ReelDecideView({
    super.key,
    required this.controller,
    required this.slot,
    required this.tv,
    this.onWatch,
    this.watchOnTv = false,
  });

  final ReelController controller;
  final ReelSlot slot;
  final bool tv;
  final VoidCallback? onWatch;

  /// Phone: Watch plays on the connected TV.
  final bool watchOnTv;

  static String get title => t.reel.decide.title;
  static String get prompt => t.reel.decide.prompt;
  static String get body => t.reel.decide.body;
  static String get nonePhone => t.reel.decide.nonePhone;
  static String get noneTv => t.reel.decide.noneTv;

  @override
  Widget build(BuildContext context) {
    if (slot.picks.isEmpty) {
      return ReelMessage(icon: Symbols.bookmarks_rounded, title: title, body: tv ? noneTv : nonePhone);
    }
    return tv ? _tv(context) : _phone(context);
  }

  Widget _tv(BuildContext context) {
    final theme = Theme.of(context);
    final scale = TvLayoutConstants.scaleOf(context);
    final chosen = slot.chosen!;
    final client = context.tryGetMediaClientWithFallback(serverIdOrNull(chosen.pick.serverId));
    final posterHeight = 186 * scale;
    final footHeight = posterHeight + 72 * scale;
    return Stack(
      fit: StackFit.expand,
      children: [
        TvSpotlightBackground(
          item: chosen.item,
          client: client,
          contentBottom: footHeight + 44 * scale,
          contentTop: 150 * scale,
        ),
        if (chosen.item == null)
          Positioned(
            left: TvLayoutConstants.horizontalInset,
            right: MediaQuery.sizeOf(context).width * 0.43,
            bottom: footHeight + 44 * scale,
            child: Text(
              chosen.pick.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.displaySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontSize: 54 * scale,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        Positioned(
          left: TvLayoutConstants.horizontalInset,
          top: 48 * scale,
          child: _Heading(scale: scale, centred: false),
        ),
        Positioned(
          left: TvLayoutConstants.horizontalInset,
          right: TvLayoutConstants.horizontalInset,
          bottom: 24 * scale,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Posters(controller: controller, slot: slot, height: posterHeight, gap: 20 * scale),
              SizedBox(height: 18 * scale),
              Row(
                children: [
                  // The Reel's own focus node keeps the keys; OK watches.
                  ExcludeFocus(
                    child: FilledButton.icon(
                      onPressed: onWatch,
                      icon: const Icon(Symbols.play_arrow_rounded, fill: 1),
                      label: Text(t.reel.card.watch),
                    ),
                  ),
                  SizedBox(width: 16 * scale),
                  Flexible(
                    child: Text(
                      t.reel.decide.hintTv,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 14 * scale,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _phone(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = slot.chosen!;
    final item = chosen.item;
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 64, 20, 24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Three posters across, never wider than a row card.
                final n = slot.picks.length;
                const gap = 12.0;
                final width = ((constraints.maxWidth - gap * 2) / 3).clamp(72.0, 132.0);
                final height = width * 3 / 2;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _Heading(scale: 1, centred: true),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: n * width + (n - 1) * gap,
                      child: _Posters(controller: controller, slot: slot, height: height, gap: gap),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      chosen.pick.title,
                      key: const ValueKey('decide:chosen'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    ReelMetadataLine(item: item, year: item?.year, fontSize: 14),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: onWatch,
                        icon: Icon(watchOnTv ? Symbols.tv_rounded : Symbols.play_arrow_rounded, fill: 1),
                        label: Text(watchOnTv ? t.reel.card.watchOnTv : t.reel.card.watch, maxLines: 1),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t.reel.decide.keepGoing,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
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

/// The card's label and its one question.
class _Heading extends StatelessWidget {
  const _Heading({required this.scale, required this.centred});

  final double scale;
  final bool centred;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centred ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        StatChip(icon: Symbols.bookmarks_rounded, label: ReelDecideView.title),
        SizedBox(height: 10 * scale),
        Text(
          ReelDecideView.prompt,
          textAlign: centred ? TextAlign.center : TextAlign.start,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: (theme.textTheme.headlineSmall?.fontSize ?? 24) * scale,
          ),
        ),
        SizedBox(height: 4 * scale),
        Text(
          ReelDecideView.body,
          textAlign: centred ? TextAlign.center : TextAlign.start,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * scale,
          ),
        ),
      ],
    );
  }
}

/// The picks as posters, the chosen one lifted with the app's focus ring.
/// They deal in one after another (still when the system asks for less
/// motion).
class _Posters extends StatelessWidget {
  const _Posters({required this.controller, required this.slot, required this.height, required this.gap});

  final ReelController controller;
  final ReelSlot slot;
  final double height;
  final double gap;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (i, p) in slot.picks.indexed) ...[
        if (i > 0) SizedBox(width: gap),
        ForkEntrance(
          key: ValueKey('decide:${p.pick.titleId}'),
          index: i,
          child: _Poster(
            pick: p,
            chosen: i == slot.pick,
            width: height * 2 / 3,
            height: height,
            onTap: () {
              ForkMotion.selection();
              controller.selectPick(i);
            },
          ),
        ),
      ],
    ],
  );
}

class _Poster extends StatelessWidget {
  const _Poster({
    required this.pick,
    required this.chosen,
    required this.width,
    required this.height,
    required this.onTap,
  });

  final ReelDecidePick pick;
  final bool chosen;
  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = ForkMotion.reduceMotion(context) ? Duration.zero : FocusTheme.getAnimationDuration(context);
    final radius = BorderRadius.circular(FocusTheme.defaultBorderRadius);
    final item = pick.item;
    final fallback = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            pick.pick.title,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: chosen,
      label: pick.pick.title,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedScale(
          scale: chosen ? FocusTheme.fullCardFocusScale : 1,
          duration: duration,
          child: AnimatedOpacity(
            opacity: chosen ? 1 : 0.62,
            duration: duration,
            child: AnimatedContainer(
              duration: duration,
              foregroundDecoration: FocusTheme.focusDecoration(
                context,
                isFocused: chosen,
                borderStrokeAlign: BorderSide.strokeAlignOutside,
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: item == null
                      ? fallback
                      : OptimizedMediaImage(
                          client: context.tryGetMediaClientWithFallback(serverIdOrNull(pick.pick.serverId)),
                          imagePath: item.thumbPath,
                          width: width,
                          height: height,
                          fit: BoxFit.cover,
                          imageType: ImageType.poster,
                          placeholder: (_, _) => fallback,
                          errorWidget: (_, _, _) => fallback,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
