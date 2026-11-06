/// What a card is about, in a line: the daily build's hook, else the
/// title's tagline, else the first sentence of its summary. Shown under the
/// title on the phone's clip-less cards and anime openings (plan V2-37, D19),
/// and the text the daily build writes its hooks from.
abstract final class ReelPremise {
  /// A hook longer than this is dropped (the card falls back to the
  /// tagline or summary).
  static const int hookWords = 12;

  /// How much of a title's own text the daily build reads per candidate.
  static const int sourceChars = 280;

  /// The phone's premise line, or null when there is nothing to say or the
  /// app's spoiler setting hides it. The setting ("hide spoilers for
  /// unwatched episodes") applies exactly as everywhere else in the app:
  /// with [hideSpoilers] on, an unwatched episode's text is never shown
  /// ([unwatchedEpisode]); a show's or film's premise is.
  static String? line({
    String? hook,
    String? tagline,
    String? summary,
    required bool hideSpoilers,
    bool unwatchedEpisode = false,
  }) {
    if (hideSpoilers && unwatchedEpisode) return null;
    return _clean(hook) ?? _clean(tagline) ?? firstSentence(summary);
  }

  /// The title's own words for the daily build: its tagline and the start
  /// of its summary, at most [sourceChars]. Null when it has neither.
  static String? source({String? tagline, String? summary}) {
    final parts = [?_clean(tagline), ?_firstSentences(summary, 2)];
    if (parts.isEmpty) return null;
    final text = parts.join(' ');
    if (text.length <= sourceChars) return text;
    final cut = text.substring(0, sourceChars);
    final space = cut.lastIndexOf(' ');
    return '${(space > sourceChars ~/ 2 ? cut.substring(0, space) : cut).trimRight()}…';
  }

  /// A hook the daily build wrote: kept only when the candidate had text of
  /// its own to write it from ([hadSource]) and it is at most [hookWords]
  /// words. Wrapping quotes are dropped.
  static String? checkedHook(String? hook, {required bool hadSource}) {
    if (!hadSource) return null;
    var h = _clean(hook);
    if (h == null) return null;
    h = h.replaceAll(RegExp(r'''^["'“‘]+|["'”’]+$'''), '').trim();
    if (h.isEmpty || h.split(' ').length > hookWords) return null;
    return h;
  }

  /// The first sentence of [text], whitespace collapsed; null when empty.
  static String? firstSentence(String? text) => _firstSentences(text, 1);

  static String? _firstSentences(String? text, int n) {
    final t = _clean(text);
    if (t == null) return null;
    var end = 0, found = 0;
    for (final m in _sentenceEnd.allMatches(t)) {
      final before = t.substring(0, m.start);
      if (_abbreviation.hasMatch(before)) continue;
      end = m.start;
      if (++found == n) break;
    }
    // Fewer than [n] sentences: all of it.
    if (found < n) return t;
    return t.substring(0, end).trim();
  }

  /// Where a sentence ends: its stop, then a space and a capital or quote.
  static final RegExp _sentenceEnd = RegExp(r'''(?<=[.!?…]["'”’)]?)\s+(?=[A-Z0-9"'“‘(])''');

  /// A stop that doesn't end a sentence: titles and single initials.
  static final RegExp _abbreviation = RegExp(r'(?:\b(?:Mr|Mrs|Ms|Dr|St|Jr|Sr|Prof|vs|Mt)|\b[A-Z])\.$');

  static String? _clean(String? s) {
    final t = s?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t == null || t.isEmpty ? null : t;
  }
}
