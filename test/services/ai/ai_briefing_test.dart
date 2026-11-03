import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/ai/ai_briefing.dart';

void main() {
  final now = DateTime(2026, 11, 3, 20);
  String? id(String s) => s;
  final ranked = [for (var i = 0; i < 20; i++) 't$i'];

  test('offers the best candidates, up to the most the model sees', () {
    expect(AiBriefing.rotate(ranked, id: id, shown: const {}), ranked.take(AiBriefing.maxCandidates));
  });

  test('leaves out titles shown lately while there are others', () {
    final shown = {'t0': now, 't2': now};
    final offered = AiBriefing.rotate(ranked, id: id, shown: shown);
    expect(offered, isNot(contains('t0')));
    expect(offered, isNot(contains('t2')));
    expect(offered.first, 't1');
  });

  test('with too few fresh titles, the ones shown longest ago make up the list', () {
    final shown = {'t0': now, 't1': now.subtract(const Duration(days: 3)), 't2': now.subtract(const Duration(days: 1))};
    expect(AiBriefing.rotate(['t0', 't1', 't2', 't3'], id: id, shown: shown), ['t3', 't1', 't2', 't0']);
  });

  test('nothing to offer', () {
    expect(AiBriefing.rotate(<String>[], id: id, shown: const {}), isEmpty);
  });
}
