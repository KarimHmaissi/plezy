import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The controller's cursor and its last stop (the pool end card).
typedef ReelCursor = ({int index, int last});

/// TV: ↑ / ↓ on the remote, with a held key's repeats coalesced (V2-66).
///
/// A press steps at once, so a tap still opens its card straight away. The
/// repeats of a held key only move [preview] on: the card view shows where
/// the hold has got to (title and artwork, nothing opened or resolved), and
/// the cursor goes there in one burst of steps when the key comes up, so
/// only the card it lands on opens. Another key, a step from the phone or a
/// pause in the repeats longer than [settle] lands it too.
class ReelHeldStep {
  ReelHeldStep({required this.cursor, required this.step, this.settle = defaultSettle});

  /// Longer than a held key's repeat interval (50 ms on Android), so it
  /// fires only when the repeats have stopped without a key up.
  static const Duration defaultSettle = Duration(milliseconds: 300);

  /// The controller's cursor, or null while the deck loads.
  final ReelCursor? Function() cursor;

  /// Moves the controller's cursor [count] cards in [dir] (±1), all in the
  /// same turn so the controller opens only the last.
  final void Function(int dir, int count) step;

  final Duration settle;

  /// The card a held key has got to, ahead of the controller's cursor; null
  /// when no hold is waiting to land.
  final ValueNotifier<int?> preview = ValueNotifier(null);

  LogicalKeyboardKey? _down;
  Timer? _settle;

  /// ↑ / ↓ events, handled; null for any other key (which lands a waiting
  /// hold first, so OK or the menu act on the card that shows).
  KeyEventResult? handle(KeyEvent event) {
    final key = event.logicalKey;
    final dir = key == LogicalKeyboardKey.arrowDown
        ? 1
        : key == LogicalKeyboardKey.arrowUp
        ? -1
        : 0;
    if (dir == 0) {
      land();
      return null;
    }
    if (event is KeyUpEvent) {
      if (_down == key) _down = null;
      land();
      // The shell saw key ups before; it still does.
      return KeyEventResult.ignored;
    }
    // Some platforms report another down instead of a repeat.
    if (event is KeyRepeatEvent || (event is KeyDownEvent && _down == key)) {
      _repeat(dir);
      return KeyEventResult.handled;
    }
    land();
    _down = key;
    step(dir, 1);
    return KeyEventResult.handled;
  }

  void _repeat(int dir) {
    final at = cursor();
    if (at == null) return;
    _settle?.cancel();
    _settle = Timer(settle, () {
      _down = null;
      land();
    });
    final from = preview.value ?? at.index;
    final to = (from + dir).clamp(0, at.last);
    if (to != from) preview.value = to;
  }

  /// Moves the cursor to where the hold got to. True when it moved.
  bool land() {
    _settle?.cancel();
    _settle = null;
    final to = preview.value;
    if (to == null) return false;
    final at = cursor();
    final n = at == null ? 0 : to - at.index;
    // The steps go first: by the time the preview clears, the controller's
    // current card is already the landed one, so the old card never shows.
    if (n != 0) step(n.sign, n.abs());
    preview.value = null;
    return n != 0;
  }

  /// Drops a waiting hold without moving (the tab hid, the app paused).
  void cancel() {
    _settle?.cancel();
    _settle = null;
    _down = null;
    preview.value = null;
  }

  void dispose() {
    _settle?.cancel();
    preview.dispose();
  }
}
