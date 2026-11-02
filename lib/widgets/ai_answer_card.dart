import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../theme/fork_motion.dart';
import '../theme/mono_tokens.dart';
import 'app_icon.dart';

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

/// A title the answer says something about.
typedef AiTitleNote = ({String title, String text, GestureRecognizer? onTap});
