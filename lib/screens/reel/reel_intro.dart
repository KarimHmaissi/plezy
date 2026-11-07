import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../widgets/fork_motion_widgets.dart';
import 'reel_card_view.dart';

/// The Reel's first-run intro (V2-55): what the Reel is and how to move
/// through it, once per device. It is drawn by the Reel screen in place of
/// the feed, never as a card: while it shows the Reel isn't started, so
/// nothing plays, nothing is recorded and no card slot is taken.
///
/// On the TV the screen keeps the keys and OK starts the Reel; on the phone
/// the button does.
class ReelIntro extends StatelessWidget {
  const ReelIntro({super.key, required this.tv, required this.onStart});

  final bool tv;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final s = t.reel.intro;
    return ForkEntrance(
      child: ReelMessage(
        icon: Symbols.movie_rounded,
        title: s.title,
        body: tv ? s.bodyTv : s.bodyPhone,
        // On the TV, OK reaches the Reel's own focus node, not this button.
        action: ExcludeFocus(
          excluding: tv,
          child: FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Symbols.play_arrow_rounded, fill: 1),
            label: Text(s.start),
          ),
        ),
      ),
    );
  }
}
