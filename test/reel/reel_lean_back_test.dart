import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/reel/reel_lean_back.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  group('ReelLeanBack quiet mode (V2-28)', () {
    test('goes quiet after 6 s of a playing clip with no key', () {
      fakeAsync((async) {
        final lb = ReelLeanBack()..begin(session: 1);
        lb.playing = true;
        async.elapse(const Duration(milliseconds: 5900));
        expect(lb.quiet, isFalse);
        async.elapse(const Duration(milliseconds: 200));
        expect(lb.quiet, isTrue);
        expect(lb.showHints, isFalse);
        lb.dispose();
      });
    });

    test('a key brings everything back and starts the 6 s again', () {
      fakeAsync((async) {
        final lb = ReelLeanBack()..begin(session: 1);
        lb.playing = true;
        async.elapse(const Duration(seconds: 7));
        expect(lb.quiet, isTrue);
        var notified = 0;
        lb.addListener(() => notified++);
        lb.poke();
        expect(lb.quiet, isFalse);
        expect(lb.showHints, isTrue);
        expect(notified, 1);
        async.elapse(const Duration(seconds: 5));
        expect(lb.quiet, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(lb.quiet, isTrue);
        lb.dispose();
      });
    });

    test('a clip that is not playing (loading, paused, held, failed) is never quiet', () {
      fakeAsync((async) {
        final lb = ReelLeanBack()..begin(session: 1);
        async.elapse(const Duration(seconds: 30));
        expect(lb.quiet, isFalse);

        lb.playing = true;
        async.elapse(const Duration(seconds: 7));
        expect(lb.quiet, isTrue);
        // The clip held (or paused, or failed): the chrome comes back at once.
        lb.playing = false;
        expect(lb.quiet, isFalse);
        async.elapse(const Duration(seconds: 30));
        expect(lb.quiet, isFalse);
        lb.dispose();
      });
    });

    test('playing again counts the 6 s from then', () {
      fakeAsync((async) {
        final lb = ReelLeanBack()..begin(session: 1);
        lb.playing = true;
        async.elapse(const Duration(seconds: 4));
        lb.playing = false;
        async.elapse(const Duration(seconds: 4));
        lb.playing = true;
        async.elapse(const Duration(seconds: 4));
        expect(lb.quiet, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(lb.quiet, isTrue);
        lb.dispose();
      });
    });

    test('leaving the Reel stops both clocks', () {
      fakeAsync((async) {
        final lb = ReelLeanBack()..begin(session: 5);
        lb.playing = true;
        lb.end();
        async.elapse(const Duration(seconds: 30));
        expect(lb.quiet, isFalse);
        expect(lb.showHints, isFalse);
        expect(async.pendingTimers, isEmpty);
        lb.dispose();
      });
    });
  });

  group('ReelLeanBack hints (CU-11)', () {
    test('the first three sessions always show them, with their room kept while quiet', () {
      fakeAsync((async) {
        for (final session in [1, 2, 3]) {
          final lb = ReelLeanBack()..begin(session: session);
          expect(lb.showHints, isTrue);
          expect(lb.hintsReserved, isTrue);
          lb.playing = true;
          async.elapse(const Duration(seconds: 7));
          expect(lb.showHints, isFalse);
          expect(lb.hintsReserved, isTrue, reason: 'they fade in place, so nothing moves');
          lb.dispose();
        }
      });
    });

    test('from the fourth, only after 10 s with no key, and a key hides them again', () {
      fakeAsync((async) {
        final lb = ReelLeanBack()..begin(session: 4);
        expect(lb.showHints, isFalse);
        expect(lb.hintsReserved, isFalse);
        async.elapse(const Duration(milliseconds: 9900));
        expect(lb.showHints, isFalse);
        async.elapse(const Duration(milliseconds: 200));
        expect(lb.showHints, isTrue);
        expect(lb.hintsReserved, isTrue);
        lb.poke();
        expect(lb.showHints, isFalse);
        expect(lb.hintsReserved, isFalse);
        lb.dispose();
      });
    });

    test('a playing clip is quiet before the 10 s, so they never cut into it', () {
      fakeAsync((async) {
        final lb = ReelLeanBack()..begin(session: 9);
        lb.playing = true;
        async.elapse(const Duration(seconds: 12));
        expect(lb.quiet, isTrue);
        expect(lb.showHints, isFalse);
        expect(lb.hintsReserved, isFalse);
        lb.dispose();
      });
    });

    test('nothing runs before the Reel comes up (the phone never starts it)', () {
      fakeAsync((async) {
        final lb = ReelLeanBack();
        lb.poke();
        lb.playing = true;
        expect(async.pendingTimers, isEmpty);
        lb.dispose();
      });
    });

    test('back from Watch is the same session', () {
      final lb = ReelLeanBack()..begin(session: 2);
      lb.end();
      lb.begin();
      expect(lb.session, 2);
      lb.dispose();
    });

    test('each visit counts on the device, up to one past the hint sessions', () async {
      resetSharedPreferencesForTest();
      final settings = await SettingsService.getInstance();
      final seen = [for (var i = 0; i < 6; i++) ReelLeanBack.countSession(settings)];
      await Future<void>.delayed(Duration.zero);
      expect(seen, [1, 2, 3, 4, 5, 5]);
      expect(settings.read(SettingsService.reelHintSessions), ReelLeanBack.hintSessions + 1);
      expect(ReelLeanBack.countSession(null), 1);
    });

    test('before any session (no settings) the hints show', () {
      final lb = ReelLeanBack();
      expect(lb.session, 0);
      expect(lb.showHints, isTrue);
      lb.dispose();
    });
  });

  test('each accepted play or pause is a new pulse', () {
    final lb = ReelLeanBack();
    lb.pulse(paused: true);
    expect(lb.transport.value!.paused, isTrue);
    expect(lb.transport.value!.count, 1);
    lb.pulse(paused: true);
    expect(lb.transport.value!.count, 2);
    lb.pulse(paused: false);
    expect(lb.transport.value!.paused, isFalse);
    lb.dispose();
  });
}
