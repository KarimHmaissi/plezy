import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/reel/reel_held_step.dart';

const _down = LogicalKeyboardKey.arrowDown;
const _up = LogicalKeyboardKey.arrowUp;

KeyEvent _press(LogicalKeyboardKey k) =>
    KeyDownEvent(physicalKey: PhysicalKeyboardKey.arrowDown, logicalKey: k, timeStamp: Duration.zero);
KeyEvent _repeat(LogicalKeyboardKey k) =>
    KeyRepeatEvent(physicalKey: PhysicalKeyboardKey.arrowDown, logicalKey: k, timeStamp: Duration.zero);
KeyEvent _release(LogicalKeyboardKey k) =>
    KeyUpEvent(physicalKey: PhysicalKeyboardKey.arrowDown, logicalKey: k, timeStamp: Duration.zero);

void main() {
  late int index;
  late int last;
  late List<String> steps;
  late ReelHeldStep held;

  setUp(() {
    index = 0;
    last = 10;
    steps = [];
    held = ReelHeldStep(
      cursor: () => (index: index, last: last),
      step: (dir, count) {
        steps.add('$dir x$count');
        index = (index + dir * count).clamp(0, last);
      },
    );
  });

  tearDown(() => held.dispose());

  test('a tap steps at once and its key up does nothing more', () {
    expect(held.handle(_press(_down)), KeyEventResult.handled);
    expect(held.handle(_release(_down)), KeyEventResult.ignored);
    expect(steps, ['1 x1']);
    expect(index, 1);
    expect(held.preview.value, isNull);
  });

  test('repeats move the preview only; the key up lands them in one burst', () {
    held.handle(_press(_down));
    for (var k = 0; k < 4; k++) {
      expect(held.handle(_repeat(_down)), KeyEventResult.handled);
    }
    expect(steps, ['1 x1'], reason: 'nothing steps while the key is held');
    expect(index, 1);
    expect(held.preview.value, 5);

    held.handle(_release(_down));
    expect(steps, ['1 x1', '1 x4']);
    expect(index, 5);
    expect(held.preview.value, isNull);
  });

  test('a held ↑ goes back and stops at the first card', () {
    index = 3;
    held.handle(_press(_up));
    for (var k = 0; k < 6; k++) {
      held.handle(_repeat(_up));
    }
    expect(held.preview.value, 0);
    held.handle(_release(_up));
    expect(steps, ['-1 x1', '-1 x2']);
    expect(index, 0);
  });

  test('a hold stops at the pool end', () {
    last = 3;
    held.handle(_press(_down));
    for (var k = 0; k < 6; k++) {
      held.handle(_repeat(_down));
    }
    expect(held.preview.value, 3);
    held.handle(_release(_down));
    expect(index, 3);
  });

  test('a hold already at the end shows no preview and lands nothing', () {
    index = 0;
    held.handle(_press(_up));
    held.handle(_repeat(_up));
    expect(held.preview.value, isNull);
    held.handle(_release(_up));
    expect(steps, ['-1 x1']);
  });

  test('a second down for the held key counts as a repeat', () {
    held.handle(_press(_down));
    held.handle(_press(_down));
    held.handle(_press(_down));
    expect(steps, ['1 x1']);
    expect(held.preview.value, 3);
    held.handle(_release(_down));
    expect(index, 3);
  });

  test('another key lands the hold first and is left to the screen', () {
    held.handle(_press(_down));
    held.handle(_repeat(_down));
    held.handle(_repeat(_down));
    final ok = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.select,
      logicalKey: LogicalKeyboardKey.select,
      timeStamp: Duration.zero,
    );
    expect(held.handle(ok), isNull);
    expect(index, 3);
    expect(held.preview.value, isNull);
  });

  test('repeats that stop without a key up land after the settle', () {
    fakeAsync((async) {
      held.handle(_press(_down));
      held.handle(_repeat(_down));
      async.elapse(ReelHeldStep.defaultSettle - const Duration(milliseconds: 10));
      held.handle(_repeat(_down));
      async.elapse(ReelHeldStep.defaultSettle - const Duration(milliseconds: 10));
      expect(steps, ['1 x1'], reason: 'each repeat restarts the settle');
      async.elapse(const Duration(milliseconds: 20));
      expect(steps, ['1 x1', '1 x2']);
      expect(held.preview.value, isNull);

      // The lost key up is forgotten: the next down is a fresh press.
      held.handle(_press(_down));
      expect(steps, ['1 x1', '1 x2', '1 x1']);
    });
  });

  test('cancel drops a waiting hold without moving', () {
    fakeAsync((async) {
      held.handle(_press(_down));
      held.handle(_repeat(_down));
      held.cancel();
      async.elapse(const Duration(seconds: 1));
      expect(held.preview.value, isNull);
      expect(steps, ['1 x1']);
      held.handle(_release(_down));
      expect(steps, ['1 x1']);
    });
  });
}
