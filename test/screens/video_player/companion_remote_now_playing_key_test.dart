import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/companion_remote/now_playing_screen.dart';
import 'package:plezy/screens/video_player/companion_remote_binding.dart';

void main() {
  String key({String? signal}) => CompanionRemoteBinding.nowPlayingKey(
    state: 'playing',
    itemId: '42',
    duration: const Duration(minutes: 44),
    audioId: '1',
    subtitleId: null,
    audioCount: 2,
    subtitleCount: 3,
    marker: null,
    hasNext: true,
    signal: signal,
  );

  test('the now-playing key changes when the signal line changes', () {
    // Otherwise the phone would wait for the heartbeat to see the switch land.
    expect(
      key(signal: '23.976 · Direct Play · EAC3 5.1'),
      isNot(key(signal: '23.976 matched · Direct Play · EAC3 5.1')),
    );
    expect(key(), isNot(key(signal: '23.976 matched')));
    expect(key(signal: '25 matched'), key(signal: '25 matched'));
  });

  test('the phone reads the signal from the payload, ignoring an empty or missing one', () {
    expect(HostNowPlaying({'signal': '23.976 matched · Direct Play'}).signal, '23.976 matched · Direct Play');
    expect(HostNowPlaying({'signal': ''}).signal, isNull);
    expect(HostNowPlaying({}).signal, isNull);
  });
}
