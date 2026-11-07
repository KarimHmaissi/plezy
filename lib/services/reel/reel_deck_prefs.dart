import 'dart:convert';

/// Where the Reel starts when it opens fresh (V2-52): For You, or the deck
/// this device was last on. Coming back from Watch or another tab always
/// keeps the deck that was playing.
enum ReelStartDeck { forYou, last }

/// The user's deck arrangement (V2-52), synced between the TV and the
/// phone: the order of the decks they moved, the decks they hid, and the
/// start deck. Decks are named by their stable ids (`for-you`,
/// `anime-openings`, `most-watched`, `ai:<answer id>`), so an arrangement
/// made on one device holds on the other even when its deck list differs.
///
/// Hidden decks leave the pickers and the → / ← deck cycle only: a deep link
/// or Reel it still opens one.
class ReelDeckPrefs {
  const ReelDeckPrefs({this.order = const [], this.hidden = const {}, this.start = ReelStartDeck.forYou});

  /// Today's behaviour: the app's own order, nothing hidden, For You first.
  static const ReelDeckPrefs none = ReelDeckPrefs();

  /// Synced setting keys (CustomisationStore).
  static const String decksKey = 'reel.decks';
  static const String startKey = 'reel.startDeck';

  /// The For You deck's id, the default start deck.
  static const String forYouId = 'for-you';

  /// Ids kept in [order] at most. Ids of decks not on this device (an older
  /// answer, Most Watched without Trakt) are kept so the other device's
  /// order survives, up to this many.
  static const int maxRemembered = 64;

  /// Deck ids in the user's order; decks not named here follow them in the
  /// app's own order (a new answer deck lands after the arranged ones).
  final List<String> order;
  final Set<String> hidden;
  final ReelStartDeck start;

  /// [decks] in the user's order, hidden ones included.
  List<T> arrange<T>(List<T> decks, String Function(T) idOf) {
    final rank = {for (final (i, id) in order.indexed) id: i};
    final named = [
      for (final d in decks)
        if (rank.containsKey(idOf(d))) d,
    ]..sort((a, b) => rank[idOf(a)]!.compareTo(rank[idOf(b)]!));
    return [
      ...named,
      for (final d in decks)
        if (!rank.containsKey(idOf(d))) d,
    ];
  }

  /// The decks the pickers and the deck cycle offer: [arrange] without the
  /// hidden ones, except [keep] (the deck playing, which may have been
  /// opened by a link). Never empty while [decks] isn't: if every deck is
  /// hidden (an arrangement synced from a device with other decks), all of
  /// them show.
  List<T> shown<T>(List<T> decks, String Function(T) idOf, {String? keep}) {
    final all = arrange(decks, idOf);
    final visible = [
      for (final d in all)
        if (!hidden.contains(idOf(d)) || idOf(d) == keep) d,
    ];
    final anyUnhidden = visible.any((d) => !hidden.contains(idOf(d)));
    return anyUnhidden ? visible : all;
  }

  /// Whether hiding [id] still leaves a deck to show among [known].
  bool canHide(Iterable<String> known, String id) => known.any((k) => k != id && !hidden.contains(k));

  /// [id] moved [by] places among [among] (the list the user sees: the
  /// shown decks in a picker, every deck on the Decks screen), clamped to
  /// its ends. A large negative [by] pins it to the top. Hidden decks
  /// between keep their places in the full order.
  ReelDeckPrefs moved({required List<String> known, List<String>? among, required String id, required int by}) {
    final full = arrange(known, (s) => s);
    final seen = among == null ? full : arrange(among, (s) => s);
    final from = seen.indexOf(id);
    if (from < 0 || by == 0) return this;
    final to = (from + by).clamp(0, seen.length - 1);
    if (to == from) return this;
    final target = seen[to];
    final next = [...full]..remove(id);
    final at = next.indexOf(target);
    next.insert(by < 0 ? at : at + 1, id);
    return _withOrder(next);
  }

  /// [id] hidden or shown again.
  ReelDeckPrefs withHidden(String id, {required bool hide}) =>
      ReelDeckPrefs(order: order, hidden: hide ? {...hidden, id} : ({...hidden}..remove(id)), start: start);

  ReelDeckPrefs withStart(ReelStartDeck s) => ReelDeckPrefs(order: order, hidden: hidden, start: s);

  /// [arranged] becomes the order; ids [order] knew that aren't in it
  /// (decks on the other device only) stay after them.
  ReelDeckPrefs _withOrder(List<String> arranged) {
    final have = arranged.toSet();
    final next = [
      ...arranged,
      for (final id in order)
        if (!have.contains(id)) id,
    ];
    return ReelDeckPrefs(order: next.take(maxRemembered).toList(), hidden: hidden, start: start);
  }

  /// The [decksKey] value: `{"order": [...], "hidden": [...]}`.
  String encodeDecks() => jsonEncode({'order': order, 'hidden': hidden.toList()..sort()});

  /// The prefs from the two synced values; anything unreadable is today's
  /// behaviour.
  static ReelDeckPrefs decode(String? decks, String? start) {
    var order = const <String>[];
    var hidden = const <String>{};
    if (decks != null) {
      try {
        final j = jsonDecode(decks);
        if (j is Map) {
          order = [...?(j['order'] as List?)?.whereType<String>()];
          hidden = {...?(j['hidden'] as List?)?.whereType<String>()};
        }
      } catch (_) {
        // Unreadable: the app's own order.
      }
    }
    final s = ReelStartDeck.values.where((v) => v.name == start).firstOrNull ?? ReelStartDeck.forYou;
    return ReelDeckPrefs(order: order, hidden: hidden, start: s);
  }

  @override
  bool operator ==(Object other) =>
      other is ReelDeckPrefs &&
      other.start == start &&
      other.order.length == order.length &&
      other.order.indexed.every((e) => order[e.$1] == e.$2) &&
      other.hidden.length == hidden.length &&
      other.hidden.containsAll(hidden);

  @override
  int get hashCode => Object.hash(start, Object.hashAll(order), Object.hashAllUnordered(hidden));
}
