import 'dart:convert';

import 'reel_library.dart';
import 'reel_store.dart';

/// Where the cursor was in a deck (V2-14): kept per deck and day on this
/// device (`cursor:<deck>:<day>`, [ReelStore.cursorKey]) on every card
/// change, so the next load of the deck's list carries on from there rather
/// than from its first card.
///
/// It names cards by id, not by place: a deck's list can differ between
/// loads (For You drops the titles gone through since its day began). [id]
/// is the card on screen; [after] the card after it, for when [id] has left
/// the list (gone through, or Not for me). [past]: the cursor was past [id]
/// (the end of the deck), so the load carries on after it.
class ReelCursor {
  const ReelCursor({required this.id, this.after, this.past = false});

  /// The card on screen ([ReelCardData.id]).
  final String id;

  /// The card after it, if there was one.
  final String? after;

  /// The cursor was at the end of the deck, after [id].
  final bool past;

  /// The cursor at [index] in [list] ([list].length: the end of the deck);
  /// null for an empty list.
  static ReelCursor? at(List<ReelCardData> list, int index) {
    if (list.isEmpty) return null;
    if (index >= list.length) return ReelCursor(id: list.last.id, past: true);
    final i = index < 0 ? 0 : index;
    return ReelCursor(id: list[i].id, after: i + 1 < list.length ? list[i + 1].id : null);
  }

  /// Where this cursor lands in [list]: on [id] (after it when [past]), else
  /// on [after]; null when neither is in [list].
  int? seekIn(List<ReelCardData> list) {
    final i = list.indexWhere((c) => c.id == id);
    if (i >= 0) return past ? i + 1 : i;
    final a = after;
    if (a == null) return null;
    final j = list.indexWhere((c) => c.id == a);
    return j < 0 ? null : j;
  }

  String encode() => jsonEncode({'id': id, 'after': ?after, if (past) 'past': true});

  /// Null for a row that isn't one (empty, or not shaped as written).
  static ReelCursor? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map<String, dynamic> || m['id'] is! String) return null;
      return ReelCursor(
        id: m['id'] as String,
        after: m['after'] is String ? m['after'] as String : null,
        past: m['past'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// The cursor kept for [deckId]: today's row for a [daily] deck (its list
  /// is built for the day), else the newest of the last [ReelStore.daysKept]
  /// days' rows. Null when there is none.
  static Future<ReelCursor?> read(ReelStore store, String deckId, {required bool daily, required DateTime now}) async {
    final days = daily ? 1 : ReelStore.daysKept;
    final keys = [
      for (var back = 0; back < days; back++) ReelStore.cursorKey(deckId, now.subtract(Duration(days: back))),
    ];
    final rows = await store.cachedMany(keys);
    for (final k in keys) {
      final c = decode(rows[k]);
      if (c != null) return c;
    }
    return null;
  }

  @override
  String toString() => past ? 'past $id' : id;
}
