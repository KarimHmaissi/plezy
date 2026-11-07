import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/reel_decay.dart';

typedef _C = ({String id, String? cluster, bool ai});

void main() {
  final now = DateTime.utc(2026, 11, 6);

  test('fatigue halves every 14 days', () {
    expect(ReelDecay.fatigue([now], now), closeTo(1, 1e-9));
    expect(ReelDecay.fatigue([now.subtract(const Duration(days: 14))], now), closeTo(0.5, 1e-9));
    expect(ReelDecay.fatigue([now, now.subtract(const Duration(days: 28))], now), closeTo(1.25, 1e-9));
  });

  test('fatigue cuts rank by at most 80%, never to zero', () {
    expect(ReelDecay.effective(1, 0), 1);
    expect(ReelDecay.effective(1, 1), closeTo(0.65, 1e-9));
    expect(ReelDecay.effective(1, 100), closeTo(0.2, 1e-9));
    expect(ReelDecay.effective(1, 100), greaterThan(0));
  });

  test('Not for me rests 90 days, then expires', () {
    expect(ReelDecay.resting(now.subtract(const Duration(days: 89)), now), isTrue);
    expect(ReelDecay.resting(now.subtract(const Duration(days: 90)), now), isFalse);
    expect(ReelDecay.resting(null, now), isFalse);
  });

  List<_C> arrange(List<_C> cards) => ReelDecay.arrange<_C>(cards, cluster: (c) => c.cluster, isAiCard: (c) => c.ai);

  test('no two neighbours share a cluster when it can be avoided', () {
    final out = arrange([
      (id: 'a1', cluster: 'a', ai: false),
      (id: 'a2', cluster: 'a', ai: false),
      (id: 'b1', cluster: 'b', ai: false),
      (id: 'a3', cluster: 'a', ai: false),
    ]);
    expect(out.map((c) => c.id), ['a1', 'b1', 'a2', 'a3']);
  });

  test('a single-cluster pool still plays in order', () {
    final out = arrange([for (var i = 0; i < 3; i++) (id: 'a$i', cluster: 'a', ai: false)]);
    expect(out.map((c) => c.id), ['a0', 'a1', 'a2']);
  });

  test('AI cards at most one in six', () {
    final cards = [
      (id: 'ai1', cluster: null, ai: true),
      (id: 'ai2', cluster: null, ai: true),
      for (var i = 0; i < 8; i++) (id: 'c$i', cluster: 'k$i', ai: false),
    ];
    final out = arrange(cards);
    final aiAt = [
      for (var i = 0; i < out.length; i++)
        if (out[i].ai) i,
    ];
    expect(aiAt, [0, 6]);
    for (var i = 1; i < aiAt.length; i++) {
      expect(aiAt[i] - aiAt[i - 1], greaterThanOrEqualTo(ReelDecay.aiCardEvery));
    }
  });

  test('AI cards that never fit wait for another day', () {
    final out = arrange([
      (id: 'c0', cluster: 'x', ai: false),
      (id: 'ai1', cluster: null, ai: true),
      (id: 'ai2', cluster: null, ai: true),
    ]);
    expect(out.map((c) => c.id), ['c0', 'ai1']);
  });
}
