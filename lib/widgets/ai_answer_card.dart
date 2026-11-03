import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../theme/fork_motion.dart';
import '../theme/mono_tokens.dart';
import '../utils/media_image_helper.dart';
import '../utils/provider_extensions.dart';
import 'app_icon.dart';
import 'fork_motion_widgets.dart';
import 'optimized_media_image.dart';
import 'pressable.dart';

/// Fork: an AI answer's text inside its row, between the row title and the
/// posters, on touch screens and desktop. No surface of its own: it belongs
/// to the row.
///
/// Open (the newest answer): what was asked on one line, the overview (three
/// lines), and a "Details" toggle for the top picks, spotlights and notes.
/// Folded (older answers): just the headline; a tap opens it. While the
/// request runs it shows the step and streams the overview as it's written;
/// a failed one says so with Retry. The follow-up chips go under the posters
/// ([AiFollowUpChips]).
class AiAnswerCard extends StatelessWidget {
  const AiAnswerCard({
    super.key,
    required this.question,
    this.text,
    this.headline,
    this.notes = const [],
    this.topPicks = const [],
    this.spotlights = const [],
    this.step,
    this.error,
    this.running = false,
    this.expanded = true,
    this.detailsOpen = false,
    this.onToggle,
    this.onDetails,
    this.onRetry,
    this.linkify,
  });

  final String question;

  /// The overview so far (streamed while [running]).
  final String? text;

  /// The gist in a few words, shown folded (else the overview's first
  /// sentence).
  final String? headline;
  final List<String> notes;

  /// The strongest matches and a few picks worth a closer look: the title
  /// (tappable with [AiTitleNote.onTap]) and what the helper says about it.
  final List<AiTitleNote> topPicks;
  final List<AiTitleNote> spotlights;

  /// What a running request is doing ("Checking your history").
  final String? step;
  final String? error;
  final bool running;
  final bool expanded;
  final bool detailsOpen;
  final VoidCallback? onToggle;
  final VoidCallback? onDetails;
  final VoidCallback? onRetry;

  /// Turns the text into spans, e.g. with the titles it names tappable.
  final List<InlineSpan> Function(String text, TextStyle? style)? linkify;

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    final muted = tokens(context).textMuted;
    final body = text?.trim();
    final hasBody = body != null && body.isNotEmpty;
    final open = expanded || running || error != null;
    final duration = ForkMotion.reduceMotion(context) ? Duration.zero : ForkMotion.sheetIn;
    final overviewStyle = theme.bodyMedium?.copyWith(height: 1.45, color: muted);
    final hasDetails = topPicks.isNotEmpty || spotlights.isNotEmpty || notes.isNotEmpty;

    void tap(VoidCallback? action) {
      if (action == null) return;
      ForkMotion.selection();
      action();
    }

    if (!open) {
      // Folded: the headline, a tap away from the rest.
      final gist = (headline?.trim().isNotEmpty ?? false) ? headline!.trim() : _firstSentence(body ?? question);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => tap(onToggle),
        child: Row(
          children: [
            Expanded(
              child: Text(
                gist,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.bodyMedium?.copyWith(color: mono.text, height: 1.4),
              ),
            ),
            const SizedBox(width: 8),
            AppIcon(Symbols.expand_more_rounded, fill: 1, size: 20, color: muted),
          ],
        ),
      );
    }

    final overview = Text.rich(
      TextSpan(children: linkify != null && !running ? linkify!(body ?? '', overviewStyle) : [TextSpan(text: body)]),
      maxLines: running || detailsOpen ? null : 3,
      overflow: running || detailsOpen ? TextOverflow.clip : TextOverflow.ellipsis,
      style: overviewStyle,
    );

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          t.aiTab.youAsked(question: question),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.labelSmall?.copyWith(color: muted),
        ),
        if (hasBody) ...[
          const SizedBox(height: 6),
          // A tap on the overview folds the answer (the newest opens again
          // with the next).
          GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => tap(onToggle), child: overview),
        ],
        if (running && step != null) ...[
          SizedBox(height: hasBody ? 10 : 8),
          Row(
            children: [
              SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: muted)),
              const SizedBox(width: 10),
              Flexible(
                child: Text(step!, style: theme.bodySmall?.copyWith(color: muted)),
              ),
            ],
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error!, style: theme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Symbols.refresh_rounded),
              label: Text(t.common.retry),
            ),
          ],
        ],
        if (!running && error == null && hasDetails && onDetails != null) ...[
          const SizedBox(height: 4),
          // A small text toggle, left-aligned under the overview.
          InkWell(
            onTap: () => tap(onDetails),
            borderRadius: BorderRadius.circular(mono.radiusSm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t.aiTab.details, style: theme.labelMedium?.copyWith(color: mono.text)),
                  const SizedBox(width: 2),
                  AnimatedRotation(
                    turns: detailsOpen ? 0.5 : 0,
                    duration: duration,
                    curve: ForkMotion.enterCurve,
                    child: AppIcon(Symbols.expand_more_rounded, fill: 1, size: 18, color: mono.text),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: duration,
            curve: ForkMotion.enterCurve,
            alignment: Alignment.topCenter,
            child: detailsOpen ? _details(context) : const SizedBox(width: double.infinity),
          ),
        ],
      ],
    );

    return AnimatedSize(
      duration: duration,
      curve: ForkMotion.enterCurve,
      alignment: Alignment.topCenter,
      child: column,
    );
  }

  /// Top picks, spotlights and notes: compact, titles semibold and tappable.
  Widget _details(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final muted = tokens(context).textMuted;
    final mono = tokens(context);
    final textStyle = theme.bodyMedium?.copyWith(height: 1.4, color: mono.text);

    Widget note(AiTitleNote p, {String? label}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: p.title,
              style: textStyle?.copyWith(fontWeight: FontWeight.w600),
              recognizer: p.onTap,
            ),
            if (label != null)
              TextSpan(
                text: '  $label',
                style: theme.labelSmall?.copyWith(color: muted),
              ),
            TextSpan(
              text: '\n${p.text}',
              style: textStyle?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final p in topPicks) note(p, label: t.aiTab.topPick),
          for (final p in spotlights) note(p),
          for (final n in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: AppIcon(Symbols.info_rounded, size: 14, color: muted),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(n, style: theme.bodySmall?.copyWith(color: muted, height: 1.4)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _firstSentence(String text) {
    final m = RegExp(r'^.+?[.!?](?=\s|$)', dotAll: true).firstMatch(text.trim());
    return m?.group(0) ?? text.trim();
  }
}

/// Fork: an answer's follow-up refinements, one line of compact chips that
/// scrolls sideways when they don't fit; under the answer's posters.
class AiFollowUpChips extends StatelessWidget {
  const AiFollowUpChips({super.key, required this.followUps, required this.onFollowUp});

  final List<String> followUps;
  final ValueChanged<String> onFollowUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final f in followUps)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text(f),
                labelStyle: theme.labelMedium,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                onPressed: () {
                  ForkMotion.selection();
                  onFollowUp(f);
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Fork: an AI answer as the first tile of its row on touch screens: the
/// top pick's art under a scrim, what was asked, the headline, and "Read"
/// in the caption band. A tap opens the answer page. While the request
/// runs it shows the step and the overview's first sentence as it streams;
/// a failed one says so and retries on tap.
class AiAnswerTile extends StatelessWidget {
  const AiAnswerTile({
    super.key,
    required this.question,
    required this.height,
    required this.band,
    this.headline,
    this.art,
    this.count = 0,
    this.step,
    this.error,
    this.running = false,
    this.onTap,
  });

  final String question;

  /// The row's artwork height, and its caption band under it.
  final double height;
  final double band;
  final String? headline;

  /// Whose backdrop sits behind the text (the top pick).
  final MediaItem? art;
  final int count;
  final String? step;
  final String? error;
  final bool running;
  final VoidCallback? onTap;

  /// Wide enough for a 12-word headline in four lines on a Fold cover.
  static double widthFor(double height) => (height * 1.12).clamp(150.0, 260.0);

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    final width = widthFor(height);
    final path = art?.artPath ?? art?.thumbPath;
    final gist = headline?.trim() ?? '';
    final radius = BorderRadius.circular(mono.radiusSm);

    final artwork = ClipRRect(
      borderRadius: radius,
      child: ForkShimmer(
        active: running,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: mono.surface),
              if (path != null)
                OptimizedMediaImage(
                  client: context.tryGetMediaClientWithFallback(serverIdOrNull(art!.serverId)),
                  imagePath: path,
                  width: width,
                  height: height,
                  imageType: ImageType.art,
                ),
              // The page's own background as the scrim, heavier where the text sits.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [mono.bg.withValues(alpha: 0.55), mono.bg.withValues(alpha: 0.92)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (running)
                      Row(
                        children: [
                          SizedBox.square(
                            dimension: 12,
                            child: CircularProgressIndicator(strokeWidth: 2, color: mono.textMuted),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            // Each new step rises in over the last one.
                            child: AnimatedSwitcher(
                              duration: ForkMotion.reduceMotion(context) ? Duration.zero : ForkMotion.sheetIn,
                              transitionBuilder: (child, animation) => ForkMotion.riseTransition(animation, child),
                              layoutBuilder: (current, previous) =>
                                  Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                              child: Text(
                                step ?? t.aiTab.starting,
                                key: ValueKey(step),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.labelSmall?.copyWith(color: mono.textMuted),
                              ),
                            ),
                          ),
                        ],
                      )
                    else
                      Text(
                        question,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.labelSmall?.copyWith(color: mono.textMuted, height: 1.3),
                      ),
                    const Spacer(),
                    if (error != null)
                      Text(
                        error!,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: theme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                      )
                    else if (gist.isNotEmpty)
                      AnimatedSwitcher(
                        duration: ForkMotion.reduceMotion(context) ? Duration.zero : ForkMotion.sheetIn,
                        child: Text(
                          gist,
                          key: ValueKey(gist.length > 40 ? gist.substring(0, 40) : gist),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: theme.titleSmall?.copyWith(
                            color: running ? mono.textMuted : mono.text,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final caption = SizedBox(
      width: width,
      height: band,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, left: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    error != null ? t.common.retry : (running ? t.aiTab.working : t.aiTab.read),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodyLarge?.copyWith(fontSize: 15, height: 1.25, color: mono.text),
                  ),
                ),
                if (!running && error == null) ...[
                  const SizedBox(width: 2),
                  AppIcon(Symbols.chevron_right_rounded, fill: 1, size: 18, color: mono.text),
                ],
              ],
            ),
            if (count > 0)
              Text(
                t.aiTab.picksCount(count: count),
                maxLines: 1,
                style: theme.bodySmall?.copyWith(fontSize: 13, height: 1.35, color: mono.textMuted),
              ),
          ],
        ),
      ),
    );

    return Pressable(
      enabled: onTap != null,
      longPress: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null
            ? null
            : () {
                ForkMotion.selection();
                onTap!();
              },
        child: Column(mainAxisSize: MainAxisSize.min, children: [artwork, caption]),
      ),
    );
  }
}

/// [text] without [title] at its start (the model naming the title its
/// line sits under): compared ignoring case and punctuation, the rest
/// capitalised. Unchanged when it doesn't start with it.
String withoutLeadingTitle(String text, String? title) {
  bool letter(String c) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c);
  final want = [
    for (final c in (title ?? '').toLowerCase().split(''))
      if (letter(c)) c,
  ];
  if (want.isEmpty) return text;
  var i = 0, matched = 0;
  while (i < text.length && matched < want.length) {
    final c = text[i].toLowerCase();
    if (letter(c)) {
      if (c != want[matched]) return text;
      matched++;
    }
    i++;
  }
  // The title must end at a word break ("Brindle has", not "Brindled").
  if (matched < want.length || (i < text.length && letter(text[i]))) return text;
  final rest = text.substring(i).replaceFirst(RegExp(r"^('s\b)?[\s:,;.\-–—]*"), '');
  if (rest.isEmpty) return text;
  // "has the same spirit" isn't a sentence alone: "It has the same spirit".
  final first = RegExp(r"^[\p{L}']+", unicode: true).firstMatch(rest)?.group(0)?.toLowerCase();
  if (first != null && _verbs.contains(first)) {
    return 'It $rest';
  }
  return rest[0].toUpperCase() + rest.substring(1);
}

/// Words a stripped reason starts with that need a subject.
const Set<String> _verbs = {
  'is',
  'has',
  'was',
  'does',
  "isn't",
  "wasn't",
  "hasn't",
  "doesn't",
  'can',
  'could',
  'will',
  'would',
  'should',
  'might',
  'may',
  'feels',
  'offers',
  'shares',
  'brings',
  'delivers',
  'mixes',
  'blends',
  'keeps',
  'gives',
  'makes',
  'packs',
  'pairs',
  'follows',
  'tells',
  'captures',
  'carries',
  'matches',
  'echoes',
  'swaps',
  'trades',
  'sits',
  'hits',
  'lands',
  'puts',
  'takes',
  'plays',
  'works',
  'leans',
  'nails',
  'balances',
  'combines',
  'stars',
  'features',
  'explores',
  'returns',
  'continues',
  'picks',
  'adds',
  'comes',
  'goes',
  'turns',
  'sets',
  'channels',
  'serves',
  'mirrors',
  'scratches',
  'swings',
  'wraps',
  'finds',
  'gets',
  'centres',
  'centers',
  'builds',
  'leaves',
};

/// A title the answer says something about.
typedef AiTitleNote = ({String title, String text, GestureRecognizer? onTap});
