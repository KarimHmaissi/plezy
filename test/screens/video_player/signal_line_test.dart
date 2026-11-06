import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/screens/video_player/signal_line.dart';

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  group('formatSignalRate', () {
    test('keeps three places for NTSC film and trims the rest', () {
      expect(formatSignalRate(24000 / 1001), '23.976');
      expect(formatSignalRate(25), '25');
      expect(formatSignalRate(60000 / 1001), '59.94');
      expect(formatSignalRate(30000 / 1001), '29.97');
      expect(formatSignalRate(120), '120');
    });
  });

  group('formatSignalLine', () {
    test('a matched direct play with E-AC3 5.1', () {
      expect(
        formatSignalLine(fps: 24000 / 1001, switched: true, transcoding: false, audioCodec: 'eac3', audioChannels: 6),
        '23.976 matched · Direct Play · E-AC3 5.1',
      );
    });

    test('a request that changed nothing says so', () {
      expect(formatSignalLine(fps: 25, switched: false, transcoding: false), '25 no switch · Direct Play');
    });

    test('with matching off the rate stands alone', () {
      expect(
        formatSignalLine(fps: 25, transcoding: true, audioCodec: 'aac', audioChannels: 2),
        '25 · Transcoding · AAC Stereo',
      );
    });

    test('live TV has no play method', () {
      expect(formatSignalLine(fps: 50, switched: true, audioCodec: 'ac3', audioChannels: 6), '50 matched · AC3 5.1');
    });

    test('names the DTS variant from the profile', () {
      expect(
        formatSignalLine(transcoding: false, audioCodec: 'dts', audioCodecProfile: 'DTS-HD MA', audioChannels: 8),
        'Direct Play · DTS-HD MA 7.1',
      );
    });

    test('null when nothing is known', () {
      expect(formatSignalLine(), isNull);
      expect(formatSignalLine(fps: 0, switched: true), isNull);
    });
  });

  group('PlaybackSignal', () {
    const eac3 = AudioTrack(id: '1', codec: 'eac3', channels: 6);

    test('the metadata rate shows until a switch reports', () {
      final signal = PlaybackSignal()..noteContentFps('a', 24000 / 1001);
      expect(signal.lineFor('a', transcoding: false, audio: eac3), '23.976 · Direct Play · E-AC3 5.1');

      signal.noteSwitch('a', 24000 / 1001, true);
      expect(signal.lineFor('a', transcoding: false, audio: eac3), '23.976 matched · Direct Play · E-AC3 5.1');
    });

    test('a reload re-asking for the matched rate keeps it matched', () {
      final signal = PlaybackSignal()
        ..noteSwitch('a', 24000 / 1001, true)
        ..noteContentFps('a', 24000 / 1001)
        ..noteSwitch('a', 24000 / 1001, false);

      expect(signal.lineFor('a'), '23.976 matched');
    });

    test('a different rate on the same item replaces the result', () {
      final signal = PlaybackSignal()
        ..noteSwitch('a', 24000 / 1001, true)
        ..noteSwitch('a', 25, false);

      expect(signal.lineFor('a'), '25 no switch');
    });

    test('the next item starts clean', () {
      final signal = PlaybackSignal()..noteSwitch('a', 24000 / 1001, true);

      expect(signal.lineFor('b', transcoding: false), 'Direct Play');
      signal.noteContentFps('b', 25);
      expect(signal.lineFor('b'), '25');
    });

    test('a resolution-only request (fps 0) records no rate', () {
      final signal = PlaybackSignal()..noteSwitch('a', 0, true);
      expect(signal.lineFor('a'), isNull);
    });

    test('selectedAudio prefers the track list entry, which carries codec and channels', () {
      const state = PlayerState(
        tracks: Tracks(
          audio: [AudioTrack(id: '2', codec: 'truehd', channels: 8)],
        ),
        track: TrackSelection(audio: AudioTrack(id: '2')),
      );
      expect(PlaybackSignal.selectedAudio(state)?.codec, 'truehd');
      expect(PlaybackSignal.selectedAudio(const PlayerState(track: TrackSelection(audio: AudioTrack.off))), isNull);
    });
  });
}
