import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/reel_volume.dart';

/// V2-49: On TV mode's volume buttons move the Reel's own level.
void main() {
  setUp(ReelVolume.reset);

  test('each press moves the level a step, held between silence and full', () {
    ReelVolume.adjust(1);
    expect(ReelVolume.level.value, 100);
    for (var i = 0; i < 3; i++) {
      ReelVolume.adjust(-1);
    }
    expect(ReelVolume.level.value, 70);
    for (var i = 0; i < 12; i++) {
      ReelVolume.adjust(-1);
    }
    expect(ReelVolume.level.value, 0);
    ReelVolume.adjust(1);
    expect(ReelVolume.level.value, 10);
  });

  test('the level scales what the clip core is sent, so the fades keep their shape', () {
    expect(ReelVolume.scale(100, 100), 100);
    expect(ReelVolume.scale(30, 50), 15);
    expect(ReelVolume.scale(100, 0), 0);
    expect(ReelVolume.scale(0, 80), 0);
  });
}
