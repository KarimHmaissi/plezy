import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/ai_composer.dart';

void main() {
  testWidgets('composer drops the keyboard when the app pauses, and on close', (tester) async {
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
    await tester.tap(find.text('Ask'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    bool focused() => FocusManager.instance.primaryFocus?.debugLabel == 'AiComposerField';
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    expect(focused(), isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(focused(), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    expect(focused(), isTrue);
    await tester.tap(find.byTooltip('Close'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Ask'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
  });
}
