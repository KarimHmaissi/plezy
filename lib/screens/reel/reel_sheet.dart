import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../services/reel/reel_controller.dart';
import '../../widgets/app_menu.dart';

enum ReelSheetAction { save, details, notForMe, spoiled, seenIt, deck }

/// Long-press OK (or the menu key) on the TV, long-press on the Fold: the
/// app's own menu sheet, Save first and focused, then the rarer choices and
/// every deck. Never prompted after a skip; swiping past is the normal "no".
Future<ReelSheetAction?> showReelSheet(BuildContext context, ReelController c, {required bool isTv}) async {
  final card = c.current.card;
  final picked = await showAdaptiveAppMenu<String>(
    context,
    title: card?.title.title,
    focusFirstItem: true,
    isScrollControlled: true,
    anchorRect: _centre(context),
    anchorAlignment: AppMenuAnchorAlignment.center,
    entries: [
      const AppMenuItem(value: 'save', icon: Symbols.bookmark_add_rounded, label: 'Save for the TV'),
      // The phone has Details on the card itself.
      if (isTv) const AppMenuItem(value: 'details', icon: Symbols.info_rounded, label: 'Details'),
      const AppMenuItem(value: 'notForMe', icon: Symbols.do_not_disturb_on_rounded, label: 'Not for me'),
      if (c.current.clip != null)
        const AppMenuItem(value: 'spoiled', icon: Symbols.visibility_off_rounded, label: 'Spoiled me'),
      const AppMenuItem(value: 'seenIt', icon: Symbols.check_rounded, label: 'Seen it'),
      // The phone picks decks from its own button at the top.
      if (isTv) ...[
        const AppMenuDivider(),
        const AppMenuHeader(label: 'Decks'),
        for (final (i, d) in c.decks.indexed)
          AppMenuItem(value: 'deck:${d.id}', icon: reelDeckIcon(d.id), label: d.name, selected: i == c.deckIndex),
      ],
    ],
  );
  if (picked == null) return null;
  if (picked.startsWith('deck:')) {
    await c.openDeck(picked.substring(5));
    return ReelSheetAction.deck;
  }
  return ReelSheetAction.values.byName(picked);
}

/// The phone's deck picker: every deck, the one playing ticked.
Future<void> showReelDeckPicker(BuildContext context, ReelController c) async {
  final picked = await showAdaptiveAppMenu<String>(
    context,
    title: 'Decks',
    isScrollControlled: true,
    anchorRect: _centre(context),
    anchorAlignment: AppMenuAnchorAlignment.center,
    entries: [
      for (final (i, d) in c.decks.indexed)
        AppMenuItem(value: d.id, icon: reelDeckIcon(d.id), label: d.name, selected: i == c.deckIndex),
    ],
  );
  if (picked != null) await c.openDeck(picked);
}

/// Each deck's icon, the same in the menu, the picker and the TV's deck
/// strip.
IconData reelDeckIcon(String id) => switch (id) {
  'for-you' => Symbols.auto_awesome_rounded,
  'anime-openings' => Symbols.music_note_rounded,
  'most-watched' => Symbols.trending_up_rounded,
  _ => Symbols.chat_bubble_rounded,
};

Rect _centre(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return Rect.fromCenter(center: Offset(size.width / 2, size.height / 2), width: 1, height: 1);
}
