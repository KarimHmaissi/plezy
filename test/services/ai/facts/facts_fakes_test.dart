import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';

import '../../../test_helpers/facts_fakes.dart';

void main() {
  test('the fakes honour the frozen interfaces', () async {
    const ref = TitleRef(id: 'm:imdb:tt1', groupKey: 'imdb:tt1', globalKey: 's:1');
    final facts = FakeTitleFactsSource({ref.id: const TitleFacts(ref: ref, seen: SeenState.unseen, imdb: 8.1)});
    expect((await facts.load([ref]))[ref.id]?.cardLine(), 'IMDb 8.1');
    expect(facts.peek('s:1')?.ref, ref);

    final media = FakeTitleMediaSource({
      ref.id: [const TitleVideo(kind: VideoKind.trailer, origin: VideoOrigin.plexExtra, title: 'Trailer')],
    });
    expect(await media.videos(ref), hasLength(1));
    expect(media.requests, [ref.id]);

    final now = DateTime.utc(2026, 11, 6);
    final ledger = FakePickLedger();
    await ledger.record([
      PickEvent(id: ref.id, surface: PickSurface.reel, action: PickAction.shown, at: now),
      PickEvent(id: ref.id, surface: PickSurface.reel, action: PickAction.notForMe, at: now),
    ]);
    expect(await ledger.resting(now: now), {ref.id});
    expect((await ledger.summaries([ref.id], now: now))[ref.id]!.resting, isTrue);
    expect(await ledger.shownWithin(const Duration(days: 5), surfaces: [PickSurface.tonight], now: now), isEmpty);
  });
}
