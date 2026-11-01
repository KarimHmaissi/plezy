import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/ai_ask_about.dart';

void main() {
  test('the recap line stops before the episode about to be watched', () {
    final p = AiPreviouslyOn.prompt((show: 'Severance', season: 2, episode: 5, title: 'Trojan Horse'), 'Catch me up');
    expect(p, contains('up to and including season 2, episode 4,'));
    expect(p, contains('Say nothing at all about season 2, episode 5 ("Trojan Horse") or anything later'));
    expect(p, contains('Call show_picks with no picks.'));
  });

  test('a season premiere recaps to the end of the season before', () {
    final p = AiPreviouslyOn.prompt((show: 'Severance', season: 2, episode: 1, title: null), 'Catch me up');
    expect(p, contains('up to and including the end of season 1,'));
    expect(p, contains('about season 2, episode 1 or anything later'));
  });
}
