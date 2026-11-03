import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../theme/fork_spacing.dart';
import '../theme/mono_tokens.dart';
import '../widgets/focusable_filter_chip.dart';
import '../widgets/fork_motion_widgets.dart';
import '../widgets/pressable.dart';

/// A mood chip: what it says, and the tuned request it runs.
typedef AiMood = ({IconData icon, String label, String request});

/// Fork: the moods under Ask, each a request worded to get a good answer.
List<AiMood> aiMoods() => [
  (icon: Symbols.local_cafe_rounded, label: t.aiTab.moodCosy, request: t.aiTab.moodCosyRequest),
  (icon: Symbols.bolt_rounded, label: t.aiTab.moodEdge, request: t.aiTab.moodEdgeRequest),
  (icon: Symbols.timer_rounded, label: t.aiTab.moodShort, request: t.aiTab.moodShortRequest),
  (icon: Symbols.sentiment_very_satisfied_rounded, label: t.aiTab.moodLaugh, request: t.aiTab.moodLaughRequest),
  (icon: Symbols.psychology_rounded, label: t.aiTab.moodMindBending, request: t.aiTab.moodMindBendingRequest),
  (icon: Symbols.headphones_rounded, label: t.aiTab.moodBackground, request: t.aiTab.moodBackgroundRequest),
];

/// Fork: one row of mood chips at the top of the AI page; a tap asks
/// straight away, no typing.
class AiMoodChips extends StatelessWidget {
  const AiMoodChips({super.key, required this.onPick});

  final ValueChanged<AiMood> onPick;

  @override
  Widget build(BuildContext context) {
    final spacing = ForkSpacing.of(context);
    final moods = aiMoods();
    return Padding(
      padding: EdgeInsets.only(bottom: spacing.titleGap),
      child: SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: spacing.edgeInset),
          itemCount: moods.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final mood = moods[i];
            return Center(
              child: ForkEntrance(
                index: i,
                child: Pressable(
                  longPress: false,
                  borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
                  child: FocusableFilterChip(icon: mood.icon, label: mood.label, onPressed: () => onPick(mood)),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
