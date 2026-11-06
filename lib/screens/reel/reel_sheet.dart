import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../services/reel/reel_controller.dart';
import '../../widgets/app_menu.dart';

enum ReelSheetAction { save, notForMe, spoiled, seenIt, deck }

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
      const AppMenuItem(value: 'notForMe', icon: Symbols.do_not_disturb_on_rounded, label: 'Not for me'),
      if (c.current.clip != null)
        const AppMenuItem(value: 'spoiled', icon: Symbols.visibility_off_rounded, label: 'Spoiled me'),
      const AppMenuItem(value: 'seenIt', icon: Symbols.check_rounded, label: 'Seen it'),
      const AppMenuDivider(),
      const AppMenuHeader(label: 'Decks'),
      for (final (i, d) in c.decks.indexed)
        AppMenuItem(value: 'deck:${d.id}', icon: Symbols.movie_rounded, label: d.name, selected: i == c.deckIndex),
    ],
  );
  if (picked == null) return null;
  if (picked.startsWith('deck:')) {
    await c.openDeck(picked.substring(5));
    return ReelSheetAction.deck;
  }
  return ReelSheetAction.values.byName(picked);
}

Rect _centre(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return Rect.fromCenter(center: Offset(size.width / 2, size.height / 2), width: 1, height: 1);
}
