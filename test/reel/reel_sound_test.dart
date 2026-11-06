import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/reel_sound.dart';
import 'package:plezy/services/settings_service.dart';

void main() {
  group('how the phone feed sound starts (V2-22)', () {
    test('the players take audio focus unless the pref says to mix', () {
      expect(ReelSound.mixWithOthers(ReelStartSound.sound), isFalse);
      expect(ReelSound.mixWithOthers(ReelStartSound.mutedIfOtherAudio), isTrue);
      expect(ReelSound.mixWithOthers(ReelStartSound.muted), isTrue, reason: 'a muted start leaves the music alone');
    });

    test('start muted: every visit, whatever was kept', () {
      const pref = ReelStartSound.muted;
      expect(ReelSound.startMuted(saved: false, pref: pref), isTrue);
      expect(ReelSound.startMuted(saved: true, pref: pref), isTrue);
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

  group('how a TV visit starts its sound', () {
    test('start muted (the TV default): muted even when the sound was left on last time', () {
      final start = ReelSound.tvVisitStart(pref: ReelStartSound.muted, saved: false);
      expect(start.muted, isTrue);
      expect(start.why, contains('start muted'));
    });

    test("a phone's muted-if-other-audio, imported onto the TV, reads as muted", () {
      expect(ReelSound.tvVisitStart(pref: ReelStartSound.mutedIfOtherAudio, saved: false).muted, isTrue);
    });

    test('with sound: sound on, unless the mute was kept or a screen reader is on', () {
      expect(ReelSound.tvVisitStart(pref: ReelStartSound.sound, saved: false).muted, isFalse);
      expect(ReelSound.tvVisitStart(pref: ReelStartSound.sound, saved: true).muted, isTrue);
      expect(ReelSound.tvVisitStart(pref: ReelStartSound.sound, saved: false, screenReader: true).muted, isTrue);
    });

    test('back from a page the Reel opened leaves the sound as it was', () {
      for (final pref in ReelStartSound.values) {
        expect(ReelSound.tvVisitStart(pref: pref, saved: false, backFromPage: true).muted, isNull);
      }
    });
  });
}
