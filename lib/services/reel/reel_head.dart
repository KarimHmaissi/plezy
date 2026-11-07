import 'dart:convert';

import 'reel_library.dart';

/// The card a deck's next cold start opens at once (V2-04): the card the
/// TV was on when the Reel was last left, kept per deck on this device
/// (`head:<deck>`, [ReelStore.headKey]). Only its identity and the deck's
/// own lines are kept: its clip and its metadata come from the Reel's own
/// caches (`src:` and `meta:` rows), as for any card.
class ReelHead {
  const ReelHead({
    required this.titleId,
    required this.serverId,
    required this.ratingKey,
    required this.day,
    required this.at,
    this.isShow,
    this.chip,
    this.why,
    this.cluster,
    this.hook,
  });

  /// The card's id ([ReelCardData.id]): the card rebuilt from the index
  /// must be the same title.
  final String titleId;
  final String serverId;
  final String ratingKey;

  /// The day it was kept ([ReelPool.dayKey]): a daily deck replays only
  /// today's.
  final String day;

  /// When it was kept.
  final DateTime at;
  final bool? isShow;
  final String? chip;
  final String? why;
  final String? cluster;
  final String? hook;

  /// The head of [card], kept on [day] at [at].
  factory ReelHead.of(ReelCardData card, {required String day, required DateTime at}) => ReelHead(
    titleId: card.id,
    serverId: card.best.serverId,
    ratingKey: card.best.ratingKey,
    day: day,
    at: at,
    isShow: card.title.isShow,
    chip: card.chip,
    why: card.why,
    cluster: card.cluster,
    hook: card.hook,
  );

  /// The deck entry the index matches it back to a card from.
  DeckEntry get entry => DeckEntry(
    serverId: serverId,
    ratingKey: ratingKey,
    isShow: isShow,
    chip: chip,
    why: why,
    cluster: cluster,
    hook: hook,
  );

  String encode() => jsonEncode({
    'id': titleId,
    'sv': serverId,
    'rk': ratingKey,
    'day': day,
    'at': at.millisecondsSinceEpoch,
    'show': ?isShow,
    'chip': ?chip,
    'why': ?why,
    'cluster': ?cluster,
    'hook': ?hook,
  });

  /// Null for a row that isn't one (empty, or not shaped as written).
  static ReelHead? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map<String, dynamic>) return null;
      final id = m['id'], sv = m['sv'], rk = m['rk'], day = m['day'], at = m['at'];
      if (id is! String || sv is! String || rk is! String || day is! String || at is! int) return null;
      String? text(String k) => m[k] is String ? m[k] as String : null;
      return ReelHead(
        titleId: id,
        serverId: sv,
        ratingKey: rk,
        day: day,
        at: DateTime.fromMillisecondsSinceEpoch(at),
        isShow: m['show'] is bool ? m['show'] as bool : null,
        chip: text('chip'),
        why: text('why'),
        cluster: text('cluster'),
        hook: text('hook'),
      );
    } catch (_) {
      return null;
    }
  }
}
