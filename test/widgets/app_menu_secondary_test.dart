import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/app_menu.dart';

/// Fork: an item's second action (`AppMenuItem.secondaryValue`), used by the
/// Reel's deck pickers to move or hide a deck.
void main() {
  late List<String> picked;

  setUp(() => picked = []);

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: Scaffold(
          body: AppMenuList<String>(
            focusFirstItem: true,
            onSelected: picked.add,
            entries: const [
              AppMenuItem(value: 'open', secondaryValue: 'arrange', label: 'Harbor Lights'),
              AppMenuItem(value: 'plain', label: 'Server A'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tap is the item, long-press its second action', (tester) async {
    await pumpList(tester);
    await tester.tap(find.text('Harbor Lights'));
    await tester.longPress(find.text('Harbor Lights'));
    expect(picked, ['open', 'arrange']);
  });

  testWidgets('OK acts on release; holding OK is the second action', (tester) async {
    await pumpList(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    expect(picked, isEmpty, reason: 'a hold may still come');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(picked, ['open']);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(picked, ['open', 'arrange']);
  });

  testWidgets('the menu key is the second action', (tester) async {
    await pumpList(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    expect(picked, ['arrange']);
  });

  testWidgets('an item without a second action still acts on OK down', (tester) async {
    await pumpList(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    expect(picked, ['plain']);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
  });
}
