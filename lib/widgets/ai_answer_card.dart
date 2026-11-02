import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../theme/fork_motion.dart';
import '../theme/fork_spacing.dart';
import '../theme/mono_tokens.dart';
import 'app_icon.dart';
import 'pressable.dart';

/// Fork: the card above an AI answer's row on touch screens and desktop:
/// what was asked, the write-up (why these picks, what ties them together,
/// or the answer to a question), and up to two "worth knowing" notes.
///
/// While the request runs it shows the step and streams the text as it's
/// written; a failed one says so with Retry. A settled card can be
/// collapsed to its first line ("More" opens it again).
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

  /// Turns the text into spans, e.g. with the titles it names tappable.
  final List<InlineSpan> Function(String text, TextStyle? style)? linkify;

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    final spacing = ForkSpacing.of(context);
    final body = text?.trim();
    final hasBody = body != null && body.isNotEmpty;
    final open = expanded || running || error != null;
    final bodyStyle = theme.bodyLarge?.copyWith(height: 1.4, color: mono.text);
    final duration = ForkMotion.reduceMotion(context) ? Duration.zero : ForkMotion.sheetIn;

    final card = Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: AnimatedSize(
          duration: duration,
          curve: ForkMotion.enterCurve,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      question,
                      maxLines: open ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.bodyMedium?.copyWith(color: mono.textMuted),
                    ),
                  ),
                  if (onToggle != null && !running && error == null && hasBody) ...[
                    const SizedBox(width: 8),
                    Text(open ? t.aiTab.less : t.aiTab.more, style: theme.labelLarge?.copyWith(color: mono.text)),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: duration,
                      curve: ForkMotion.enterCurve,
                      child: AppIcon(Symbols.expand_more_rounded, fill: 1, size: 20, color: mono.text),
                    ),
                  ],
                ],
              ),
              if (hasBody) ...[
                const SizedBox(height: 8),
                Text.rich(
                  TextSpan(children: linkify != null && !running ? linkify!(body, bodyStyle) : [TextSpan(text: body)]),
                  maxLines: open ? null : 1,
                  overflow: open ? TextOverflow.clip : TextOverflow.ellipsis,
                  style: bodyStyle,
                ),
              ],
              if (running && step != null) ...[
                SizedBox(height: hasBody ? 10 : 8),
                Row(
                  children: [
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: mono.textMuted),
                    ),
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
              if (open && !running && notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final note in notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
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
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final f in followUps)
                      ActionChip(
                        label: Text(f),
                        onPressed: () {
                          ForkMotion.selection();
                          onFollowUp!(f);
                        },
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(spacing.edgeInset, 0, spacing.edgeInset, spacing.titleGap + 4),
      child: onToggle == null || running || error != null
          ? card
          : Pressable(
              longPress: false,
              borderRadius: BorderRadius.circular(14),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  ForkMotion.selection();
                  onToggle!();
                },
                child: card,
              ),
            ),
    );
  }
}
