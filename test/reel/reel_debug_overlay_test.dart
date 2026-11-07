import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/reel/reel_debug_overlay.dart';
import 'package:plezy/services/reel/reel_perf.dart';

void main() {
  late Duration now;
  late ReelPerf perf;

  setUp(() {
    now = Duration.zero;
    perf = ReelPerf(now: () => now)..recording = true;
  });

  void card(ReelPerfTrigger t, {required int ms, bool preloaded = true}) {
    perf.begin(t);
    final start = now;
    perf.markResolved(preloaded: preloaded);
    now = start + Duration(milliseconds: ms ~/ 2);
    perf.markOpened();
    now = start + Duration(milliseconds: ms);
    perf.markFirstFrame();
  }

  Future<void> pump(WidgetTester tester, {required bool tv}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReelDebugOverlay(perf: perf, tv: tv),
        ),
      ),
    );
    // The entrance animation.
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('phone: last and median swipe times, hit rate, decoders, no decoder split', (tester) async {
    perf.liveDecoders = () => 3;
    card(ReelPerfTrigger.swipe, ms: 80);
    card(ReelPerfTrigger.swipe, ms: 120, preloaded: false);
    card(ReelPerfTrigger.swipe, ms: 100);
    await pump(tester, tv: false);

    expect(find.text('swipe → frame 100 ms · p50 100'), findsOneWidget);
    expect(find.text('open 50 · p50 50'), findsOneWidget);
    expect(find.text('preload 67% (2/3)'), findsOneWidget);
    expect(find.text('decoders 3'), findsOneWidget);
    expect(find.textContaining('decoder '), findsNothing);
    expect(find.textContaining('frames over 0/0'), findsOneWidget);

    // A new card updates the chips at once.
    card(ReelPerfTrigger.swipe, ms: 40);
    await tester.pump();
    expect(find.text('swipe → frame 40 ms · p50 80'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TV: shows the decoder split and never takes focus or taps', (tester) async {
    card(ReelPerfTrigger.key, ms: 200);
    await pump(tester, tv: true);
    expect(find.text('key → frame 200 ms · p50 200'), findsOneWidget);
    expect(find.text('decoder – · p50 –'), findsOneWidget);
    expect(find.ancestor(of: find.byType(ReelPerfChips), matching: find.byType(IgnorePointer)), findsWidgets);
    expect(find.ancestor(of: find.byType(ReelPerfChips), matching: find.byType(ExcludeFocus)), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('before any card: dashes, not zeros', (tester) async {
    await pump(tester, tv: false);
    expect(find.text('swipe → frame – ms · p50 –'), findsOneWidget);
    expect(find.text('preload –'), findsOneWidget);
    expect(find.text('decoders –'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
