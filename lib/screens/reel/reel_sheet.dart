import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/reel/reel_controller.dart';
import '../../services/settings_service.dart' show ReelOkAction;
import '../../widgets/app_menu.dart';
import '../settings/reel_decks_screen.dart';

export '../settings/reel_decks_screen.dart' show reelDeckIcon;

enum ReelSheetAction {
  watchHere,
  save,
  moreLike,
  watch,
  details,
  notForMe,
  spoiled,
  seenIt,
  sound,
  settings,
  deck,
  arrangeDecks,
}

/// Long-press OK (or the menu key) on the TV, long-press on the Fold: the
/// app's own menu sheet, Save first and focused, then the rarer choices, the
/// Reel's settings and every shown deck. Never prompted after a skip;
/// swiping past is the normal "no".
///
/// On the TV the sheet offers whichever of Watch and Details OK does not
/// ([okAction], D12), and the clip's sound (V2-50): the phone has both on
/// the card itself.
///
/// [watchHere]: the Fold is connected to a TV, so its Watch goes there;
/// "Watch here" comes first and plays the title on the phone instead.
///
/// A deck's second action (hold OK or the menu key on it) opens its own
/// menu: move, pin to the top, hide (V2-52).
Future<ReelSheetAction?> showReelSheet(
  BuildContext context,
  ReelController c, {
  required bool isTv,
  ReelOkAction okAction = ReelOkAction.watch,
  bool watchHere = false,
}) async {
  final card = c.current.card;
  final muted = c.clips.muted;
  final picked = await showAdaptiveAppMenu<String>(
    context,
    title: card?.title.title,
    focusFirstItem: true,
    isScrollControlled: true,
    anchorRect: _centre(context),
    anchorAlignment: AppMenuAnchorAlignment.center,
    entries: [
      if (watchHere && card != null)
        AppMenuItem(value: 'watchHere', icon: Symbols.smartphone_rounded, label: t.reel.sheet.watchHere),
      AppMenuItem(value: 'save', icon: Symbols.bookmark_add_rounded, label: t.reel.sheet.saveForTv),
      if (c.canMoreLike)
        AppMenuItem(value: 'moreLike', icon: Symbols.auto_awesome_motion_rounded, label: t.reel.sheet.moreLike),
      // The phone has Details on the card itself.
      if (isTv && okAction == ReelOkAction.details)
        AppMenuItem(value: 'watch', icon: Symbols.play_arrow_rounded, label: t.reel.sheet.watch)
      else if (isTv)
        AppMenuItem(value: 'details', icon: Symbols.info_rounded, label: t.reel.sheet.details),
      AppMenuItem(value: 'notForMe', icon: Symbols.do_not_disturb_on_rounded, label: t.reel.sheet.notForMe),
      if (c.current.clip != null)
        AppMenuItem(value: 'spoiled', icon: Symbols.visibility_off_rounded, label: t.reel.sheet.spoiledMe),
      AppMenuItem(value: 'seenIt', icon: Symbols.check_rounded, label: t.reel.sheet.seenIt),
      // The phone has its own mute button at the top.
      if (isTv)
        AppMenuItem(
          value: 'sound',
          icon: muted ? Symbols.volume_up_rounded : Symbols.volume_off_rounded,
          label: muted ? t.reel.card.soundOn : t.reel.sheet.soundOff,
        ),
      AppMenuItem(value: 'settings', icon: Symbols.tune_rounded, label: t.reel.settings.sheetEntry),
      // The phone picks decks from its own button at the top.
      if (isTv) ...[
        const AppMenuDivider(),
        AppMenuHeader(label: t.reel.decks.title),
        ..._deckEntries(c, prefix: 'deck:'),
        _arrangeEntry(isTv: true),
      ],
    ],
  );
  if (picked == null || !context.mounted) return null;
  if (picked.startsWith('deck:')) {
    await c.openDeck(picked.substring(5));
    return ReelSheetAction.deck;
  }
  if (picked.startsWith(_arrangePrefix)) {
    await showReelDeckActions(context, c, picked.substring(_arrangePrefix.length));
    return ReelSheetAction.deck;
  }
  if (picked == _arrangeAll) return ReelSheetAction.arrangeDecks;
  return ReelSheetAction.values.byName(picked);
}

/// The phone's deck picker: every shown deck in the user's order, the one
/// playing ticked. Holding a deck opens its own menu (move, pin to the top,
/// hide), then the picker comes back with the new order; "Arrange decks"
/// opens the Decks screen.
Future<void> showReelDeckPicker(BuildContext context, ReelController c) async {
  while (true) {
    if (!context.mounted) return;
    final picked = await showAdaptiveAppMenu<String>(
      context,
      title: t.reel.decks.title,
      isScrollControlled: true,
      anchorRect: _centre(context),
      anchorAlignment: AppMenuAnchorAlignment.center,
      entries: [..._deckEntries(c), _arrangeEntry(isTv: false)],
    );
    if (picked == null || !context.mounted) return;
    if (picked == _arrangeAll) {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => reelDecksScreenFor(c)));
      return;
    }
    if (!picked.startsWith(_arrangePrefix)) return c.openDeck(picked);
    final changed = await showReelDeckActions(context, c, picked.substring(_arrangePrefix.length));
    if (!changed) return;
  }
}

/// One deck's own menu, from a deck's second action in either picker: move
/// up or down among the shown decks, pin it to the top, hide it (or show it
/// again: the deck playing stays in the pickers while hidden). The last
/// shown deck can't be hidden. True when something was picked.
Future<bool> showReelDeckActions(BuildContext context, ReelController c, String id) async {
  final s = t.reel.decks;
  final shown = [for (final d in c.shownDecks) d.id];
  final i = shown.indexOf(id);
  if (i < 0) return false;
  final hidden = c.isHidden(id);
  final picked = await showAdaptiveAppMenu<String>(
    context,
    title: c.shownDecks[i].name,
    focusFirstItem: true,
    isScrollControlled: true,
    anchorRect: _centre(context),
    anchorAlignment: AppMenuAnchorAlignment.center,
    entries: [
      if (i > 0) ...[
        AppMenuItem(value: 'up', icon: Symbols.arrow_upward_rounded, label: s.moveUp),
        if (i > 1) AppMenuItem(value: 'top', icon: Symbols.vertical_align_top_rounded, label: s.moveToTop),
      ],
      if (i < shown.length - 1) AppMenuItem(value: 'down', icon: Symbols.arrow_downward_rounded, label: s.moveDown),
      if (hidden)
        AppMenuItem(value: 'show', icon: Symbols.visibility_rounded, label: s.show)
      else if (c.deckPrefs.canHide([for (final d in c.decks) d.id], id))
        AppMenuItem(value: 'hide', icon: Symbols.visibility_off_rounded, label: s.hide),
    ],
  );
  switch (picked) {
    case 'up':
      await c.moveDeck(id, -1);
    case 'top':
      await c.moveDeck(id, -shown.length);
    case 'down':
      await c.moveDeck(id, 1);
    case 'hide':
      await c.hideDeck(id, hide: true);
    case 'show':
      await c.hideDeck(id, hide: false);
    default:
      return false;
  }
  return true;
}

/// The Decks screen over the Reel's own decks (answers it built since it
/// opened included).
Widget reelDecksScreenFor(ReelController c) =>
    ReelDecksScreen(decks: (_) async => [for (final d in c.decks) (id: d.id, name: d.name)]);

const String _arrangePrefix = 'arrange:';
const String _arrangeAll = 'arrangeDecks';

/// The shown decks, each with its second action (`arrange:<id>`).
List<AppMenuEntry<String>> _deckEntries(ReelController c, {String prefix = ''}) => [
  for (final d in c.shownDecks)
    AppMenuItem(
      value: '$prefix${d.id}',
      secondaryValue: '$_arrangePrefix${d.id}',
      icon: reelDeckIcon(d.id),
      label: d.name,
      subtitle: c.isHidden(d.id) ? t.reel.decks.hidden : null,
      selected: d.id == c.deck.id,
    ),
];

AppMenuItem<String> _arrangeEntry({required bool isTv}) => AppMenuItem(
  value: _arrangeAll,
  icon: Symbols.reorder_rounded,
  label: t.reel.decks.arrange,
  subtitle: isTv ? t.reel.decks.arrangeHintTv : t.reel.decks.arrangeHintPhone,
);

Rect _centre(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return Rect.fromCenter(center: Offset(size.width / 2, size.height / 2), width: 1, height: 1);
}
