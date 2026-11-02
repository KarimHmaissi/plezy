import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../theme/fork_motion.dart';
import '../theme/mono_tokens.dart';
import 'app_icon.dart';

/// Fork: an AI answer's text inside its row, between the row title and the
/// posters, on touch screens and desktop: what was asked, the write-up (why
/// these picks, or the answer to a question), up to two "worth knowing"
/// notes and follow-up chips. No surface of its own: it belongs to the row.
///
/// While the request runs it shows the step and streams the text as it's
/// written; a failed one says so with Retry. A settled answer can fold to
/// its first line ("More" opens it again).
class AiAnswerCard extends StatelessWidget {
  const AiAnswerCard({
    super.key,
    required this.question,
    this.text,
    this.notes = const [],
    this.followUps = const [],
    this.step,
    this.error,
    this.running = false,
    this.expanded = true,
    this.onToggle,
    this.onRetry,
    this.onFollowUp,
    this.linkify,
    this.topPicks = const [],
    this.spotlights = const [],
  });

  final String question;

  /// The write-up so far (streamed while [running]).
  final String? text;
  final List<String> notes;

  /// Refinements to ask next, as chips under the text.
  final List<String> followUps;

  /// What a running request is doing ("Checking your history").
  final String? step;
  final String? error;
  final bool running;
  final bool expanded;
  final VoidCallback? onToggle;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onFollowUp;

  /// The strongest matches and a few picks worth a closer look: the title
  /// (tappable with [AiTitleNote.onTap]) and what the helper says about it.
  final List<AiTitleNote> topPicks;
  final List<AiTitleNote> spotlights;

  /// Turns the text into spans, e.g. with the titles it names tappable.
  final List<InlineSpan> Function(String text, TextStyle? style)? linkify;

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    final body = text?.trim();
    final hasBody = body != null && body.isNotEmpty;
    final open = expanded || running || error != null;
    final canToggle = onToggle != null && !running && error == null && hasBody;
    final bodyStyle = theme.bodyLarge?.copyWith(height: 1.4, color: mono.text);
    final duration = ForkMotion.reduceMotion(context) ? Duration.zero : ForkMotion.sheetIn;

    // Folded: the overview's first sentence.
    final shown = open || body == null ? body : _firstSentence(body);
    Widget bodyText = Text.rich(
      TextSpan(children: linkify != null && !running ? linkify!(shown ?? '', bodyStyle) : [TextSpan(text: shown)]),
      maxLines: open ? null : 2,
      overflow: open ? TextOverflow.clip : TextOverflow.ellipsis,
      style: bodyStyle,
    );
    if (canToggle) {
      bodyText = Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: bodyText),
          const SizedBox(width: 8),
          Text(open ? t.aiTab.less : t.aiTab.more, style: theme.labelLarge?.copyWith(color: mono.text)),
          AnimatedRotation(
            turns: open ? 0.5 : 0,
            duration: duration,
            curve: ForkMotion.enterCurve,
            child: AppIcon(Symbols.expand_more_rounded, fill: 1, size: 20, color: mono.text),
          ),
        ],
      );
    }

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          t.aiTab.youAsked(question: question),
          maxLines: open ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          style: theme.bodySmall?.copyWith(color: mono.textMuted),
        ),
        if (hasBody) ...[const SizedBox(height: 6), bodyText],
        if (running && step != null) ...[
          SizedBox(height: hasBody ? 10 : 8),
          Row(
            children: [
              SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: mono.textMuted)),
              const SizedBox(width: 10),
              Flexible(
                child: Text(step!, style: theme.bodySmall?.copyWith(color: mono.textMuted)),
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
        if (open && !running && topPicks.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final p in topPicks)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${t.aiTab.topPick}  ',
                      style: theme.labelLarge?.copyWith(color: mono.textMuted),
                    ),
                    _titleSpan(p, theme.bodyLarge?.copyWith(color: mono.text, height: 1.4)),
                    TextSpan(text: ' — ${p.text}'),
                  ],
                ),
                style: theme.bodyLarge?.copyWith(color: mono.text, height: 1.4),
              ),
            ),
        ],
        if (open && !running && spotlights.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(t.aiTab.spotlight, style: theme.labelLarge?.copyWith(color: mono.textMuted)),
          const SizedBox(height: 6),
          for (final p in spotlights)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text.rich(
                TextSpan(
                  children: [
                    _titleSpan(p, theme.bodyMedium?.copyWith(color: mono.text, height: 1.4)),
                    TextSpan(text: '\n${p.text}'),
                  ],
                ),
                style: theme.bodyMedium?.copyWith(color: mono.text, height: 1.4),
              ),
            ),
        ],
        if (open && !running && notes.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: AppIcon(Symbols.info_rounded, size: 16, color: mono.textMuted),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(note, style: theme.bodyMedium?.copyWith(color: mono.textMuted, height: 1.35)),
                  ),
                ],
              ),
            ),
        ],
        if (open && !running && followUps.isNotEmpty && onFollowUp != null) ...[
          const SizedBox(height: 8),
          // One line; scrolls sideways when the chips don't fit.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
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
                      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                      onPressed: () {
                        ForkMotion.selection();
                        onFollowUp!(f);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );

    final animated = AnimatedSize(
      duration: duration,
      curve: ForkMotion.enterCurve,
      alignment: Alignment.topCenter,
      child: column,
    );
    if (!canToggle) return animated;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        ForkMotion.selection();
        onToggle!();
      },
      child: animated,
    );
  }

  static TextSpan _titleSpan(AiTitleNote p, TextStyle? style) => TextSpan(
    text: p.title,
    style: style?.copyWith(fontWeight: FontWeight.w600, decoration: p.onTap == null ? null : TextDecoration.underline),
    recognizer: p.onTap,
  );

  static String _firstSentence(String text) {
    final m = RegExp(r'^.+?[.!?](?=\s|$)', dotAll: true).firstMatch(text);
    return m?.group(0) ?? text;
  }
}

/// A title the answer says something about.
typedef AiTitleNote = ({String title, String text, GestureRecognizer? onTap});
