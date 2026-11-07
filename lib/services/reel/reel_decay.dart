import 'dart:math' as math;

/// Fork (Reel): the only ranking code the Reel keeps (spec §7). The daily AI
/// build decides the order; code applies fatigue from quick skips, the
/// 90-day Not-for-me rest, and two layout rules. Nothing here ever bans a
/// title for good.
class ReelDecay {
  const ReelDecay._();

  /// A quick skip's weight halves every 14 days.
  static const double halfLifeDays = 14;

  /// Fatigue never cuts a title's rank by more than this.
  static const double maxCut = 0.8;
  static const double perUnit = 0.35;

  /// Not for me rests a title this long, then it may come back.
  static const Duration rest = Duration(days: 90);

  /// AI (still-art) cards: at most one in this many.
  static const int aiCardEvery = 6;

  /// Σ quick skips · 0.5^(age_days / 14).
  static double fatigue(Iterable<DateTime> quickSkips, DateTime now) {
    var f = 0.0;
    for (final at in quickSkips) {
      final days = now.difference(at).inMinutes / (60 * 24);
      f += math.pow(0.5, math.max(0, days) / halfLifeDays);
    }
    return f;
  }

  /// rank · (1 − min(0.8, 0.35 · fatigue)): never reaches zero.
  static double effective(double rank, double fatigue) => rank * (1 - math.min(maxCut, perUnit * fatigue));

  static bool resting(DateTime? notForMeAt, DateTime now) => notForMeAt != null && now.difference(notForMeAt) < rest;

  /// Reorders [cards] as little as possible so that no two neighbours share
  /// a cluster and AI cards are at most one in [aiCardEvery]. A card that
  /// can't be placed yet waits for the next slot that fits; AI cards that
  /// never fit are dropped from this pass (they come back another day).
  static List<T> arrange<T>(List<T> cards, {required String? Function(T) cluster, required bool Function(T) isAiCard}) {
    final out = <T>[];
    final waiting = [...cards];
    var sinceAi = aiCardEvery; // the first card may be an AI card
    while (waiting.isNotEmpty) {
      final last = out.isEmpty ? null : cluster(out.last);
      final i = waiting.indexWhere((c) {
        if (isAiCard(c) && sinceAi < aiCardEvery) return false;
        final k = cluster(c);
        return last == null || k == null || k != last;
      });
      if (i < 0) {
        // Nothing fits: relax adjacency for the first non-AI card, so the
        // feed never stalls on a single-cluster pool.
        final j = waiting.indexWhere((c) => !isAiCard(c));
        if (j < 0) break;
        out.add(waiting.removeAt(j));
        sinceAi++;
        continue;
      }
      final c = waiting.removeAt(i);
      out.add(c);
      sinceAi = isAiCard(c) ? 1 : sinceAi + 1;
    }
    return out;
  }
}
