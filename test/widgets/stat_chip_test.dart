import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/widgets/stat_chip.dart';

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('the default chip keeps its labelMedium size and padding', (tester) async {
    await tester.pumpWidget(_host(const StatChip(icon: Symbols.check_rounded, label: 'Seen')));
    final box = tester.widget<Container>(find.byType(Container));
    expect(box.padding, const EdgeInsets.symmetric(horizontal: 10, vertical: 5));
    final context = tester.element(find.byType(StatChip));
    final label = tester.widget<Text>(find.text('Seen'));
    expect(label.style?.fontSize, Theme.of(context).textTheme.labelMedium?.fontSize);
  });

  testWidgets('a sized chip scales its padding and icon with the label', (tester) async {
    await tester.pumpWidget(_host(const StatChip(icon: Symbols.check_rounded, label: 'Seen', fontSize: 18)));
    final context = tester.element(find.byType(StatChip));
    final k = 18 / Theme.of(context).textTheme.labelMedium!.fontSize!;
    final box = tester.widget<Container>(find.byType(Container));
    expect(box.padding, EdgeInsets.symmetric(horizontal: 10 * k, vertical: 5 * k));
    expect(tester.widget<Text>(find.text('Seen')).style?.fontSize, 18);
  });

  testWidgets('sizeFor is the size the chip lays out at', (tester) async {
    for (final (fontSize, icon) in [(null, false), (13.6, true), (21.6, true), (16.0, false)]) {
      await tester.pumpWidget(
        _host(StatChip(icon: icon ? Symbols.check_rounded : null, label: '#1 show this week', fontSize: fontSize)),
      );
      final context = tester.element(find.byType(StatChip));
      final expected = StatChip.sizeFor(context, '#1 show this week', icon: icon, fontSize: fontSize);
      final actual = tester.getSize(find.byType(StatChip));
      expect(actual.width, closeTo(expected.width, 0.01), reason: 'width at $fontSize');
      expect(actual.height, closeTo(expected.height, 0.01), reason: 'height at $fontSize');
    }
  });
}
