import 'package:plezy/services/ai/facts/title_facts.dart';

/// Facts handed out from a fixed map, for surfaces built against the
/// frozen Straight Facts interfaces.
class FakeTitleFactsSource implements TitleFactsSource {
  FakeTitleFactsSource([Map<TitleId, TitleFacts>? facts]) : facts = {...?facts};

  final Map<TitleId, TitleFacts> facts;
  final List<List<TitleRef>> loads = [];

  @override
  Future<Map<TitleId, TitleFacts>> load(Iterable<TitleRef> refs) async {
    final list = refs.toList();
    loads.add(list);
    return {
      for (final r in list)
        if (facts[r.id] != null) r.id: facts[r.id]!,
    };
  }

  @override
  TitleFacts? peek(String globalKey) => facts.values.where((f) => f.ref.globalKey == globalKey).firstOrNull;
}

/// Videos from a fixed map; records every request so tests can prove a
/// surface asks per title and never in bulk.
class FakeTitleMediaSource implements TitleMediaSource {
  FakeTitleMediaSource([Map<TitleId, List<TitleVideo>>? byTitle]) : byTitle = {...?byTitle};

  final Map<TitleId, List<TitleVideo>> byTitle;
  final List<TitleId> requests = [];

  @override
  Future<List<TitleVideo>> videos(TitleRef ref) async {
    requests.add(ref.id);
    return byTitle[ref.id] ?? const [];
  }
}

/// An in-memory ledger that keeps every event.
class FakePickLedger implements PickLedger {
  final List<PickEvent> events = [];

  @override
  Future<void> record(List<PickEvent> events) async => this.events.addAll(events);

  @override
  Future<Map<TitleId, LedgerSummary>> summaries(Iterable<TitleId> ids, {DateTime? now}) async => {
    for (final id in ids)
      id: LedgerSummary(
        timesShown: events.where((e) => e.id == id && e.action == PickAction.shown).length,
        notForMeAt: events.where((e) => e.id == id && e.action == PickAction.notForMe).lastOrNull?.at,
        now: now,
      ),
  };

  @override
  Future<Set<TitleId>> shownWithin(Duration window, {Iterable<PickSurface>? surfaces, DateTime? now}) async {
    final from = (now ?? DateTime.now()).subtract(window);
    final on = surfaces?.toSet();
    return {
      for (final e in events)
        if (e.action == PickAction.shown && e.at.isAfter(from) && (on == null || on.contains(e.surface))) e.id,
    };
  }

  @override
  Future<String> promptFacts({DateTime? now, int maxLines = 40}) async => '';

  @override
  Future<Set<TitleId>> resting({DateTime? now}) async {
    final at = now ?? DateTime.now();
    return {
      for (final e in events)
        if (e.action == PickAction.notForMe && at.difference(e.at) < const Duration(days: 90)) e.id,
    };
  }
}
