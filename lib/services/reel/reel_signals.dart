import 'dart:convert';

import '../../utils/app_logger.dart';
import 'reel_store.dart';

/// One kind of thing done to one title, [n] times. This device's own events
/// come one by one with their time; the other device's come per day (timed
/// at that day's noon).
typedef ReelSignal = ({String titleId, ReelAction action, DateTime at, int n});

/// What the Reel saw them do, on this device and the other one, for the
/// daily build's facts (V2-36). Facts only: nothing here ranks a title.
///
/// Events stay in each device's own database; each device also shares a
/// small per-day aggregate of its last [keepDays] days (title → action
/// codes) through the synced settings, so the TV's build hears what was
/// done on the phone and the other way round. The TV and a phone write
/// different keys, so neither overwrites the other's.
class ReelSignals {
  ReelSignals({required this.store, required this.host, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final ReelStore store;

  /// This device builds the day's pool (the TV, a desktop); otherwise a phone.
  final bool host;
  final DateTime Function() _clock;

  /// The aggregate a host shares, and the one a phone shares.
  static const String hostKey = 'reel.signals.host';
  static const String phoneKey = 'reel.signals.phone';

  /// Days the shared aggregate covers (the facts read the last 30).
  static const int keepDays = 30;

  /// Titles kept per day in the shared aggregate, so it stays small.
  static const int maxTitlesPerDay = 150;

  /// One letter per action in the shared aggregate. [ReelAction.unplayed] is
  /// neutral and never shared.
  static const Map<ReelAction, String> _codes = {
    ReelAction.sampled: 's',
    ReelAction.quickSkip: 'q',
    ReelAction.toEnd: 'e',
    ReelAction.replay: 'r',
    ReelAction.unmute: 'u',
    ReelAction.watch: 'w',
    ReelAction.watchOnTv: 't',
    ReelAction.save: 'v',
    ReelAction.notForMe: 'n',
    ReelAction.spoiled: 'x',
    ReelAction.seenIt: 'k',
    ReelAction.forKids: 'f',
    ReelAction.details: 'd',
  };
  static final Map<String, ReelAction> _actions = {for (final MapEntry(:key, :value) in _codes.entries) value: key};

  String get _ownKey => host ? hostKey : phoneKey;
  String get _otherKey => host ? phoneKey : hostKey;

  /// The calendar day of [d], `YYYY-MM-DD`.
  static String _dateOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// This device's own events since [since], [ReelAction.unplayed] left out.
  Future<List<ReelSignal>> _own({required DateTime since}) async => [
    for (final e in await store.events(since: since))
      if (_actionOf(e.action) case final a? when a != ReelAction.unplayed)
        (titleId: e.titleId, action: a, at: DateTime.fromMillisecondsSinceEpoch(e.at), n: 1),
  ];

  static ReelAction? _actionOf(String name) => ReelAction.values.where((a) => a.name == name).firstOrNull;

  /// The aggregate of this device's last [keepDays] days, as shared:
  /// `{v: 1, days: {YYYY-MM-DD: {titleId: 'sse'}}}`.
  Future<String> _encodeOwn() async {
    final now = _clock();
    final since = DateTime(now.year, now.month, now.day).subtract(const Duration(days: keepDays - 1));
    final days = <String, Map<String, String>>{};
    for (final s in await _own(since: since)) {
      final day = days[_dateOf(s.at)] ??= {};
      if (!day.containsKey(s.titleId) && day.length >= maxTitlesPerDay) continue;
      day[s.titleId] = (day[s.titleId] ?? '') + _codes[s.action]!;
    }
    return jsonEncode({'v': 1, 'days': days});
  }

  /// Shares this device's aggregate (when it changed). Called when a Reel
  /// session ends; a phone mirroring a TV it has lost can't write, and that
  /// is fine: the next session shares it.
  Future<void> publish() async {
    try {
      final value = await _encodeOwn();
      if (await store.readSignals(_ownKey) == value) return;
      await store.writeSignals(_ownKey, value);
    } catch (e) {
      appLogger.d('Reel: sharing the Reel signals failed', error: e);
    }
  }

  /// The other device's aggregate since [since], or nothing.
  Future<List<ReelSignal>> _other({required DateTime since}) async {
    final String? raw;
    try {
      raw = await store.readSignals(_otherKey);
    } catch (e) {
      appLogger.d('Reel: the other device signals are unavailable', error: e);
      return const [];
    }
    return decode(raw, since: since);
  }

  /// A shared aggregate as signals since [since] (each day timed at its
  /// noon); anything it can't read is left out.
  static List<ReelSignal> decode(String? raw, {required DateTime since}) {
    if (raw == null) return const [];
    final Object? j;
    try {
      j = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (j is! Map || j['days'] is! Map) return const [];
    final from = DateTime(since.year, since.month, since.day);
    final out = <ReelSignal>[];
    for (final MapEntry(key: day, value: titles) in (j['days'] as Map).entries) {
      final date = DateTime.tryParse('$day');
      if (date == null || date.isBefore(from) || titles is! Map) continue;
      final at = DateTime(date.year, date.month, date.day, 12);
      for (final MapEntry(key: id, value: codes) in titles.entries) {
        if (codes is! String) continue;
        final counts = <ReelAction, int>{};
        for (final c in codes.split('')) {
          if (_actions[c] case final a?) counts[a] = (counts[a] ?? 0) + 1;
        }
        for (final MapEntry(key: a, value: n) in counts.entries) {
          out.add((titleId: '$id', action: a, at: at, n: n));
        }
      }
    }
    return out;
  }

  /// Everything the Reel saw since [since]: this device's events and the
  /// other device's aggregate.
  Future<List<ReelSignal>> since(DateTime since) async => [...await _own(since: since), ...await _other(since: since)];

  /// Quick skips per title on both devices within [within] (the fatigue
  /// window), for the build's fatigue fact.
  Future<Map<String, List<DateTime>>> quickSkips({Duration within = const Duration(days: 120)}) async {
    final out = await store.quickSkips(within: within);
    for (final s in await _other(since: _clock().subtract(within))) {
      if (s.action != ReelAction.quickSkip) continue;
      (out[s.titleId] ??= []).addAll(List.filled(s.n, s.at));
    }
    return out;
  }

  /// Count of [action] in [signals].
  static int count(Iterable<ReelSignal> signals, ReelAction action) =>
      signals.where((s) => s.action == action).fold(0, (n, s) => n + s.n);

  /// The counts the facts name, in order: `(label, actions)`.
  static const List<(String, List<ReelAction>)> _counted = [
    ('sampled', [ReelAction.sampled]),
    ('watched to the end', [ReelAction.toEnd]),
    ('skipped within 2 s', [ReelAction.quickSkip]),
    ('Not for me', [ReelAction.notForMe]),
    ('saved', [ReelAction.save]),
    ('played', [ReelAction.watch, ReelAction.watchOnTv]),
    ('opened Details', [ReelAction.details]),
    ('replayed', [ReelAction.replay]),
    ('unmuted', [ReelAction.unmute]),
  ];

  /// "3 sampled, 1 Not for me, …": the non-zero counts in [signals].
  static String countsLine(Iterable<ReelSignal> signals) => [
    for (final (label, actions) in _counted)
      if (actions.fold(0, (n, a) => n + count(signals, a)) case final n when n > 0) '$n $label',
  ].join(', ');

  /// Per-cluster lines: the signals of titles the pool labelled ([clusters]:
  /// title id → `cl`), busiest kind first, at most [max].
  static List<String> clusterLines(Iterable<ReelSignal> signals, Map<String, String> clusters, {int max = 12}) {
    final by = <String, List<ReelSignal>>{};
    for (final s in signals) {
      final cl = clusters[s.titleId];
      if (cl != null) (by[cl] ??= []).add(s);
    }
    int total(List<ReelSignal> l) => l.fold(0, (n, s) => n + s.n);
    final sorted = by.entries.toList()..sort((a, b) => total(b.value).compareTo(total(a.value)));
    return [
      for (final e in sorted.take(max))
        if (countsLine(e.value) case final line when line.isNotEmpty) '- ${e.key}: $line',
    ];
  }

  /// Per-candidate facts for the titles in [ids]: a save not played since,
  /// clips watched to the end, Details opened, replays and unmutes. [picks]
  /// are the synced saves (title id → when).
  static Map<String, List<String>> notes(
    Iterable<ReelSignal> signals,
    Set<String> ids, {
    required Map<String, DateTime> picks,
    required DateTime now,
  }) {
    final by = <String, List<ReelSignal>>{};
    for (final s in signals) {
      if (ids.contains(s.titleId)) (by[s.titleId] ??= []).add(s);
    }
    String times(int n) => n == 1 ? '' : ' $n×';
    final out = <String, List<String>>{};
    for (final id in ids) {
      final list = by[id] ?? const <ReelSignal>[];
      final lines = <String>[];
      DateTime? saved = picks[id];
      for (final s in list) {
        if (s.action == ReelAction.save && (saved == null || s.at.isAfter(saved))) saved = s.at;
      }
      if (saved != null) {
        final at = saved;
        final played = list.any(
          (s) => (s.action == ReelAction.watch || s.action == ReelAction.watchOnTv) && !s.at.isBefore(at),
        );
        if (!played) lines.add('saved ${_ago(at, now)}, not played yet');
      }
      final toEnd = count(list, ReelAction.toEnd);
      if (toEnd > 0) lines.add('clip watched to the end${times(toEnd)}');
      final details = count(list, ReelAction.details);
      if (details > 0) lines.add('opened Details${times(details)}');
      final replays = count(list, ReelAction.replay);
      if (replays > 0) lines.add('replayed${times(replays)}');
      if (count(list, ReelAction.unmute) > 0) lines.add('unmuted');
      if (lines.isNotEmpty) out[id] = lines;
    }
    return out;
  }

  /// "today", "yesterday" or "n days ago", by calendar day.
  static String _ago(DateTime at, DateTime now) {
    final local = at.toLocal();
    final gap = DateTime(now.year, now.month, now.day).difference(DateTime(local.year, local.month, local.day));
    // Hours, rounded: a day across a clock change is 23 or 25 hours long.
    final days = (gap.inHours / 24).round();
    return switch (days) {
      <= 0 => 'today',
      1 => 'yesterday',
      _ => '$days days ago',
    };
  }
}
