import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/ai_composer.dart';

Future<void> _frames(WidgetTester tester, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('composer keeps the keyboard through the iris and the IME opening', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => AiComposer.open(context, run: (_) async => const AiComposerOutcome()),
                child: const Text('Ask'),
              ),
            ),
          ),
        ),
      ),
    );
    bool focused() => FocusManager.instance.primaryFocus?.debugLabel == 'AiComposerField';

    await tester.tap(find.text('Ask'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60)); // mid-iris
    await tester.tap(find.byType(EditableText), warnIfMissed: false);
    await tester.enterText(find.byType(EditableText), 'cosy');
    await _frames(tester, 20); // iris finishes
    expect(focused(), isTrue);
    expect(find.text('cosy'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isTrue);

    // The IME opening: Samsung reports inactive and the inset grows.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.view.viewInsets = FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
    await _frames(tester, 4);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _frames(tester, 2);
    expect(focused(), isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    // A real trip to the background puts it away.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(focused(), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.resetViewInsets();

    await tester.tap(find.byType(EditableText));
    await tester.pump();
    expect(focused(), isTrue);
    await tester.tap(find.byTooltip('Close'));
    await _frames(tester, 20);
    expect(find.text('Ask'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
  });
}
