import 'package:flutter/material.dart';

import '../../services/reel/reel_controller.dart';
import 'reel_card_view.dart';

enum ReelSheetAction { save, notForMe, spoiled, seenIt, deck }

/// Long-press OK (or ≡) on the TV, long-press on the Fold: Save first and
/// focused, then the rarer choices and every deck. Never prompted after a
/// skip; swiping past is the normal "no".
Future<ReelSheetAction?> showReelSheet(BuildContext context, ReelController c, {required bool isTv}) {
  final card = c.current.card;
  return showGeneralDialog<ReelSheetAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: const Color(0x99000000),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) => Align(
      alignment: isTv ? Alignment.centerRight : Alignment.bottomCenter,
      child: Material(
        color: ReelInk.booth,
        child: SafeArea(
          child: SizedBox(
            width: isTv ? 360 : double.infinity,
            height: isTv ? double.infinity : null,
            child: ListView(
              shrinkWrap: !isTv,
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
              children: [
                if (card != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Text(
                      card.title.title,
                      style: const TextStyle(color: ReelInk.paper, fontSize: 22, fontWeight: FontWeight.w800),
                    ),
                  ),
                _item(context, Icons.bookmark_add_rounded, 'Save for the TV', ReelSheetAction.save, autofocus: true),
                _item(context, Icons.do_not_disturb_on_outlined, 'Not for me', ReelSheetAction.notForMe),
                if (c.current.clip != null)
                  _item(context, Icons.visibility_off_outlined, 'Spoiled me', ReelSheetAction.spoiled),
                _item(context, Icons.check_rounded, 'Seen it', ReelSheetAction.seenIt),
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 18, 4, 8),
                  child: Text(
                    'DECKS',
                    style: TextStyle(color: ReelInk.dim, fontSize: 11, letterSpacing: 2.4, fontWeight: FontWeight.w700),
                  ),
                ),
                for (final (i, d) in c.decks.indexed)
                  ListTile(
                    dense: true,
                    selected: i == c.deckIndex,
                    selectedColor: ReelInk.lamp,
                    textColor: ReelInk.paper,
                    title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      Navigator.of(context).pop(ReelSheetAction.deck);
                      c.openDeck(d.id);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(
        begin: isTv ? const Offset(1, 0) : const Offset(0, 1),
        end: Offset.zero,
      ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(a),
      child: child,
    ),
  );
}

Widget _item(BuildContext context, IconData icon, String label, ReelSheetAction action, {bool autofocus = false}) =>
    ListTile(
      autofocus: autofocus,
      leading: Icon(icon, color: ReelInk.lamp),
      title: Text(
        label,
        style: const TextStyle(color: ReelInk.paper, fontWeight: FontWeight.w600),
      ),
      focusColor: const Color(0x33F2B84B),
      onTap: () => Navigator.of(context).pop(action),
    );
