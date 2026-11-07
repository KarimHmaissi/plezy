import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/reel/reel_pinch.dart';

/// The feed's gesture stack in miniature (V2-33): a vertical [PageView]
/// that pages, a sideways swipe over each page, tap, double-tap and
/// long-press on it, and the pinch over the lot, as the phone feed has them.
class _Arena {
  final List<String> events = [];
  final List<double> ratios = [];
  int page = 0;
  final PageController pages = PageController();

  Widget build() => MaterialApp(
    home: Scaffold(
      body: PageView.builder(
        controller: pages,
        scrollDirection: Axis.vertical,
        itemCount: 4,
        onPageChanged: (p) => page = p,
        itemBuilder: (context, i) => RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: {
            ReelPinchRecognizer: GestureRecognizerFactoryWithHandlers<ReelPinchRecognizer>(
              ReelPinchRecognizer.new,
              (r) => r
                ..onStart = (() => events.add('pinch start'))
                ..onUpdate = ratios.add
                ..onEnd = ((ratio) => events.add('pinch end ${ratio.toStringAsFixed(2)}')),
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (_) => events.add('sideways'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => events.add('tap'),
              onDoubleTap: () => events.add('double tap'),
              onLongPress: () => events.add('long press'),
              child: ColoredBox(
                color: Colors.black,
                child: Center(child: Text('Page $i')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late _Arena arena;

  setUp(() => arena = _Arena());
  tearDown(() => arena.pages.dispose());

  Future<Offset> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(arena.build());
    return tester.getCenter(find.byType(PageView));
  }

  /// Two fingers [gap] apart, one above the other; the top one moves by
  /// [top] and the bottom one by [bottom], in [steps] moves.
  Future<void> pinch(
    WidgetTester tester,
    Offset centre, {
    double gap = 80,
    Offset top = Offset.zero,
    Offset bottom = Offset.zero,
    int steps = 5,
  }) async {
    final a = await tester.startGesture(centre + Offset(0, gap / 2), pointer: 1);
    final b = await tester.startGesture(centre - Offset(0, gap / 2), pointer: 2);
    for (var i = 0; i < steps; i++) {
      await b.moveBy(top / steps.toDouble());
      await a.moveBy(bottom / steps.toDouble());
      await tester.pump(const Duration(milliseconds: 16));
    }
    await b.up();
    await a.up();
    await tester.pumpAndSettle();
  }

  group('one finger never reaches the pinch', () {
    testWidgets('a swipe up pages', (tester) async {
      await pump(tester);
      await tester.fling(find.byType(PageView), const Offset(0, -400), 1500);
      await tester.pumpAndSettle();
      expect(arena.page, 1);
      expect(arena.events, isEmpty);
    });

    testWidgets('a sideways swipe is the sideways swipe', (tester) async {
      await pump(tester);
      await tester.fling(find.text('Page 0'), const Offset(300, 0), 1500);
      await tester.pumpAndSettle();
      expect(arena.events, ['sideways']);
      expect(arena.page, 0);
    });

    testWidgets('tap, double-tap and long-press all answer', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Page 0'));
      await tester.pumpAndSettle(kDoubleTapTimeout);
      await tester.tap(find.text('Page 0'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Page 0'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Page 0'));
      await tester.pumpAndSettle();
      expect(arena.events, ['tap', 'double tap', 'long press']);
    });
  });

  group('two fingers are a pinch', () {
    testWidgets('a pinch out reports its spread and never pages, even when the newest finger moves up', (tester) async {
      final centre = await pump(tester);
      // The finger that lands last runs up 200: on its own that is a page.
      await pinch(tester, centre, top: const Offset(0, -200));
      expect(arena.page, 0, reason: 'the pinch took both fingers from the paging');
      expect(arena.pages.page, 0);
      expect(arena.events, ['pinch start', 'pinch end 3.50']);
      expect(arena.ratios.last, closeTo(3.5, 0.01));
      expect(arena.ratios, orderedEquals([...arena.ratios]..sort()), reason: 'it follows the fingers out');
    });

    testWidgets('a pinch in reports a ratio under 1, and no tap or sideways swipe fires', (tester) async {
      final centre = await pump(tester);
      await pinch(tester, centre, gap: 200, top: const Offset(40, 50), bottom: const Offset(-40, -50));
      await tester.pumpAndSettle(kDoubleTapTimeout);
      expect(arena.events.first, 'pinch start');
      expect(arena.events, hasLength(2));
      expect(arena.ratios.last, lessThan(1 / reelPinchStep));
      expect(arena.page, 0);
    });

    testWidgets('a swipe already under way is never taken by a second finger', (tester) async {
      final centre = await pump(tester);
      final a = await tester.startGesture(centre, pointer: 11);
      // Past the touch slop: the page is being dragged.
      for (var i = 0; i < 4; i++) {
        await a.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // A second finger lands below and both run on up (the drag follows
      // the newest finger): a pinch would take both and stop the page.
      final b = await tester.startGesture(centre + const Offset(0, 300), pointer: 12);
      for (var i = 0; i < 4; i++) {
        await a.moveBy(const Offset(0, -80));
        await b.moveBy(const Offset(0, -80));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(arena.pages.position.pixels, greaterThan(400), reason: 'past the middle, still paging');
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(arena.events, isEmpty);
      expect(arena.page, 1);
    });

    testWidgets('a third finger joins the pinch without paging or changing its spread', (tester) async {
      final centre = await pump(tester);
      final a = await tester.startGesture(centre + const Offset(0, 40), pointer: 1);
      final b = await tester.startGesture(centre - const Offset(0, 40), pointer: 2);
      final c = await tester.startGesture(centre + const Offset(100, 0), pointer: 3);
      for (var i = 0; i < 5; i++) {
        await c.moveBy(const Offset(0, -80));
        await b.moveBy(const Offset(0, -8));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await c.up();
      await b.up();
      await a.up();
      await tester.pumpAndSettle();
      expect(arena.page, 0);
      expect(arena.events, ['pinch start', 'pinch end 1.50']);
    });

    testWidgets('after a pinch, one finger pages again', (tester) async {
      final centre = await pump(tester);
      await pinch(tester, centre, top: const Offset(0, -100));
      await tester.fling(find.byType(PageView), const Offset(0, -400), 1500);
      await tester.pumpAndSettle();
      expect(arena.page, 1);
      expect(arena.events, hasLength(2));
    });
  });

  group('the fill rules', () {
    test('out past the step fills, in past it fits, and a nudge leaves it', () {
      expect(reelPinchFills(filled: false, ratio: 1.2), isTrue);
      expect(reelPinchFills(filled: true, ratio: 1.5), isTrue);
      expect(reelPinchFills(filled: true, ratio: 0.8), isFalse);
      expect(reelPinchFills(filled: false, ratio: 0.5), isFalse);
      expect(reelPinchFills(filled: false, ratio: 1.03), isFalse);
      expect(reelPinchFills(filled: true, ratio: 0.97), isTrue);
    });

    test('the fill scale is BoxFit.cover over the fitted frame', () {
      // Upright: a 16:9 frame 400 wide is 225 tall; covering 800 is ×3.56.
      expect(reelFillZoom(const Size(400, 800), 16 / 9, 1), closeTo(800 / 225, 1e-9));
      // On its side the frame is height-bound at 400 and 711 wide.
      expect(reelFillZoom(const Size(800, 400), 16 / 9, 1), closeTo(800 / (400 * 16 / 9), 1e-9));
      // Fit is no scale; halfway is halfway.
      expect(reelFillZoom(const Size(400, 800), 16 / 9, 0), 1);
      expect(reelFillZoom(const Size(400, 800), 16 / 9, 0.5), closeTo((1 + 800 / 225) / 2, 1e-9));
      // A clip already the page's shape has nothing to fill.
      expect(reelFillZoom(const Size(400, 800), 0.5, 1), 1);
      expect(reelFillZoom(Size.zero, 16 / 9, 1), 1);
    });

    test('the pinch moves the fill with the fingers and stops at the ends', () {
      expect(reelPinchFill(from: 0, ratio: 2, cover: 2), closeTo(1, 1e-9));
      expect(reelPinchFill(from: 0, ratio: 1.5, cover: 4), closeTo(0.2925, 1e-3));
      expect(reelPinchFill(from: 1, ratio: 0.5, cover: 2), closeTo(0, 1e-9));
      expect(reelPinchFill(from: 0, ratio: 10, cover: 2), 1);
      expect(reelPinchFill(from: 0.4, ratio: 1, cover: 2), 0.4);
      // A clip that barely grows still answers a small pinch.
      expect(reelPinchFill(from: 0, ratio: 1.25, cover: 1.05), closeTo(1, 1e-9));
    });
  });
}
