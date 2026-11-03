import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/ai/ai_briefing.dart';

void main() {
  final now = DateTime(2026, 11, 3, 20);
  String? id(String s) => s;
  final ranked = [for (var i = 0; i < 20; i++) 't$i'];

  test('draws from the best few, the best most often', () {
    AiBriefing.random = Random(1);
    final counts = <String, int>{};
    for (var i = 0; i < 2000; i++) {
      final t = AiBriefing.draw(ranked, id: id, shown: const {})!;
      counts[t] = (counts[t] ?? 0) + 1;
    }
    expect(counts.keys.toSet(), {for (var i = 0; i < AiBriefing.drawFrom; i++) 't$i'});
    expect(counts['t0']!, greaterThan(counts['t${AiBriefing.drawFrom - 1}']!));
  });

  test('skips titles shown lately while there are others', () {
    AiBriefing.random = Random(2);
    final shown = {for (var i = 0; i < 19; i++) 't$i': now};
    expect(AiBriefing.draw(ranked, id: id, shown: shown), 't19');
  });

  test('when every title was shown, the one shown longest ago', () {
    final shown = {
      't0': now,
      't1': now.subtract(const Duration(days: 3)),
      't2': now.subtract(const Duration(days: 1)),
    };
    expect(AiBriefing.draw(['t0', 't1', 't2'], id: id, shown: shown), 't1');
  });

  test('nothing to draw from', () {
    expect(AiBriefing.draw(<String>[], id: id, shown: const {}), isNull);
  });
}
