import 'dart:async';
import 'dart:math' as math;

import '../../utils/app_logger.dart';
import '../ai/facts/title_facts.dart';
import '../companion_remote/phone_mode.dart';
import 'reel_decay.dart';
import 'reel_signals.dart';
import 'reel_store.dart';

/// Fork (V2-44): the pick ledger over the Reel's own records, so Ask, its
/// Tonight picks, the AI rows and the facts every surface reads hear what
/// the Reel showed and what happened next. It adopts `ReelEvents` and the
/// Not for me vetoes as they are (`surface = reel`) and adds no store of its
/// own.
///
/// Facts, not weights: a title "shown 3× in the Reel lately, not played
/// yet" is told to the model, which decides for itself (an explicit ask for
/// it still gets it). Nothing here ranks or filters a title; the only
/// filter is [resting], for code-built pools.
///
/// What counts as a showing (the recommender plan's impression rules):
/// - 8 s or more of a clip (`sampled`, `toEnd`), or an explicit action on
///   the card (Save, Not for me, Details, More like this, replay, unmute,
///   Watch). Scrolling past records nothing, and a quick skip (< 2 s) or a
///   card left before its clip played is not a showing.
/// - Events on one title within [visitGap] of each other are one showing
///   (a sample and a Save in the same visit count once).
/// - Showings older than [lately] say nothing: after 60 days without being
///   shown a title has no impression facts at all.
/// - The other device's events arrive per day ([ReelSignals]), so they
///   count at most one showing a day, over the 30 days it shares.
///
/// Outcome: a Reel Watch at or after the first showing means it took. A
/// real watch anywhere else reaches the surfaces through the seen state
/// ([LedgerSummary.seenAt]). It is "not played yet", never a rejection.
class ReelLedger implements PickLedger {
  ReelLedger({
    required this.store,
    bool Function()? host,
    DateTime Function()? clock,
    this.cacheFor = const Duration(minutes: 1),
  }) : _host = host ?? (() => !PhoneMode.isHandheld),
       _clock = clock ?? DateTime.now;

  /// The app's ledger over [ReelStore.instance].
  static final ReelLedger instance = ReelLedger(store: ReelStore.instance);

  final ReelStore store;

  /// This device builds the day's pool (the TV, a desktop): which shared
  /// aggregate is its own ([ReelSignals.host]). Read on every rebuild.
  final bool Function() _host;
  final DateTime Function() _clock;

  /// How long one [snapshot] is reused: surfaces load facts in bursts.
  final Duration cacheFor;

  /// Showings older than this say nothing.
  static const Duration lately = Duration(days: 60);

  /// A Reel Watch within this long of a showing means it took.
  static const Duration tookWithin = Duration(days: 90);

  /// "Passed on in Aug" is said for this long after Not for me.
  static const Duration passedOnSaid = Duration(days: 180);

  /// Events closer together than this are one visit to the card.
  static const Duration visitGap = Duration(minutes: 30);

  /// A Reel showing's weight, and its half-life (the recommender plan's
  /// surface table).
  static const double reelWeight = 0.5;
  static const double halfLifeDays = 21;

  /// The actions that make a showing.
  static const Set<ReelAction> showing = {
    ReelAction.sampled,
    ReelAction.toEnd,
    ReelAction.replay,
    ReelAction.unmute,
    ReelAction.save,
    ReelAction.notForMe,
    ReelAction.details,
    ReelAction.moreLikeThis,
    ReelAction.watch,
    ReelAction.watchOnTv,
  };

  static const Set<ReelAction> _played = {ReelAction.watch, ReelAction.watchOnTv};

  ({DateTime at, Future<Map<TitleId, LedgerSummary>> all})? _cached;

  /// Every title the Reel has a fact about, by title id: shown lately, or
  /// passed on within [passedOnSaid], as of [now] (the clock by default).
  /// One read is reused for [cacheFor].
  Future<Map<TitleId, LedgerSummary>> snapshot({DateTime? now}) {
    final at = now ?? _clock();
    final c = _cached;
    if (c != null && at.difference(c.at) < cacheFor && !at.isBefore(c.at)) return c.all;
    final all = _build(at);
    _cached = (at: at, all: all);
    // A failed read isn't kept (the caller still hears the error).
    unawaited(
      all.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_cached?.all, all)) _cached = null;
        },
      ),
    );
    return all;
  }

  /// Drops the reused [snapshot].
  void forget() => _cached = null;

  Future<Map<TitleId, LedgerSummary>> _build(DateTime now) async {
    final started = DateTime.now();
    final signals = await ReelSignals(store: store, host: _host(), clock: () => now).since(now.subtract(tookWithin));
    final passed = await store.passedOn();
    final out = summarise(signals, passed, now: now);
    appLogger.d(
      'Reel ledger: ${out.length} titles '
      '(${out.values.where((s) => s.timesShown > 0).length} shown lately, '
      '${out.values.where((s) => s.notForMeAt != null).length} passed on) '
      'from ${signals.length} signals in ${DateTime.now().difference(started).inMilliseconds} ms',
    );
    return out;
  }

  /// The summaries [signals] and the Not for me times [passedOn] make at
  /// [now]. Pure, for tests.
  static Map<TitleId, LedgerSummary> summarise(
    Iterable<ReelSignal> signals,
    Map<String, DateTime> passedOn, {
    required DateTime now,
  }) {
    final shows = <String, List<DateTime>>{};
    final plays = <String, List<DateTime>>{};
    for (final s in signals) {
      if (showing.contains(s.action)) (shows[s.titleId] ??= []).add(s.at);
      if (_played.contains(s.action)) (plays[s.titleId] ??= []).add(s.at);
    }
    final out = <TitleId, LedgerSummary>{};
    for (final id in {...shows.keys, ...passedOn.keys}) {
      final visits = _visits(shows[id] ?? const []);
      final recent = visits.where((at) => now.difference(at) < lately).toList();
      final first = visits.isEmpty ? null : visits.first;
      final took =
          first != null && (plays[id] ?? const []).any((p) => !p.isBefore(first) && p.difference(first) < tookWithin);
      final passed = passedOn[id];
      final saidPassed = passed != null && now.difference(passed) < passedOnSaid ? passed : null;
      if (recent.isEmpty && saidPassed == null) continue;
      out[id] = LedgerSummary(
        shownWeight: recent.fold(
          0.0,
          (w, at) =>
              w + reelWeight * math.pow(0.5, math.max(0, now.difference(at).inMinutes / (60 * 24)) / halfLifeDays),
        ),
        timesShown: recent.length,
        lastShown: recent.isEmpty ? null : recent.last,
        surfaces: recent.isEmpty ? const {} : const {PickSurface.reel},
        outcome: took ? PickOutcome.took : PickOutcome.pending,
        notForMeAt: saidPassed,
        now: now,
      );
    }
    return out;
  }

  /// [times] as visits: each visit's first time, oldest first.
  static List<DateTime> _visits(List<DateTime> times) {
    final sorted = [...times]..sort();
    final out = <DateTime>[];
    DateTime? last;
    for (final at in sorted) {
      if (last == null || at.difference(last) >= visitGap) out.add(at);
      last = at;
    }
    return out;
  }

  /// The Reel writes its own events ([ReelStore.record]); this ledger only
  /// reads them. Events for other surfaces have no store yet.
  @override
  Future<void> record(List<PickEvent> events) async {
    if (events.isEmpty) return;
    appLogger.d(
      'Reel ledger: ${events.length} events not kept (the Reel records its own; other surfaces have no store)',
    );
  }

  @override
  Future<Map<TitleId, LedgerSummary>> summaries(Iterable<TitleId> ids, {DateTime? now}) async {
    final all = await snapshot(now: now);
    return {for (final id in ids) id: ?all[id]};
  }

  @override
  Future<Set<TitleId>> shownWithin(Duration window, {Iterable<PickSurface>? surfaces, DateTime? now}) async {
    if (surfaces != null && !surfaces.contains(PickSurface.reel)) return const {};
    final at = now ?? _clock();
    final from = at.subtract(window);
    return {
      for (final s in await ReelSignals(store: store, host: _host(), clock: () => at).since(from))
        if (showing.contains(s.action) && !s.at.isBefore(from)) s.titleId,
    };
  }

  /// One line of the Reel's last 30 days ("Reel, last 30 days: 40 sampled,
  /// 2 saved, 1 played"), or empty.
  @override
  Future<String> promptFacts({DateTime? now, int maxLines = 40}) async {
    final at = now ?? _clock();
    final signals = await ReelSignals(
      store: store,
      host: _host(),
      clock: () => at,
    ).since(at.subtract(const Duration(days: 30)));
    final counts = ReelSignals.countsLine(signals);
    return counts.isEmpty || maxLines < 1 ? '' : 'Reel, last 30 days: $counts';
  }

  @override
  Future<Set<TitleId>> resting({DateTime? now}) async {
    final at = now ?? _clock();
    return {
      for (final MapEntry(:key, :value) in (await store.passedOn()).entries)
        if (ReelDecay.resting(value, at)) key,
    };
  }
}
