import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/reel_sound.dart';
import 'package:plezy/services/settings_service.dart';

void main() {
  group('how the phone feed sound starts (V2-22)', () {
    test('the players take audio focus unless the pref says to mix', () {
      expect(ReelSound.mixWithOthers(ReelStartSound.sound), isFalse);
      expect(ReelSound.mixWithOthers(ReelStartSound.mutedIfOtherAudio), isTrue);
    });

    test('with sound, a visit starts muted only when the mute was kept or the TV is playing', () {
      const pref = ReelStartSound.sound;
      expect(ReelSound.startMuted(saved: false, pref: pref), isFalse);
      expect(ReelSound.startMuted(saved: false, pref: pref, otherAudio: true), isFalse, reason: 'music pauses instead');
      expect(ReelSound.startMuted(saved: true, pref: pref), isTrue);
      expect(ReelSound.startMuted(saved: false, pref: pref, tvPlaying: true), isTrue);
    });

    test('muted if other audio is playing', () {
      const pref = ReelStartSound.mutedIfOtherAudio;
      expect(ReelSound.startMuted(saved: false, pref: pref), isFalse);
      expect(ReelSound.startMuted(saved: false, pref: pref, otherAudio: true), isTrue);
      expect(ReelSound.startMuted(saved: true, pref: pref), isTrue);
    });

    test("the TV counts as playing only on the companion's playing state", () {
      expect(ReelSound.tvPlaying(null), isFalse);
      expect(ReelSound.tvPlaying({'state': 'playing', 'title': 'Harbor Lights'}), isTrue);
      expect(ReelSound.tvPlaying({'state': 'paused', 'title': 'Harbor Lights'}), isFalse);
    });

    test('other audio is never reported where it cannot be told', () async {
      // The test host is not Android.
      expect(await ReelSound.otherAudioPlaying(), isFalse);
    });
  });
}
