import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/reel_premise.dart';

void main() {
  group('the premise line', () {
    test('the hook comes first, then the tagline, then the first sentence of the summary', () {
      const summary = 'A ferry pilot finds a letter in the hold. Nothing on the island is what it seems.';
      expect(
        ReelPremise.line(
          hook: 'A ferry pilot and a letter',
          tagline: 'Every tide returns',
          summary: summary,
          hideSpoilers: false,
        ),
        'A ferry pilot and a letter',
      );
      expect(
        ReelPremise.line(tagline: 'Every tide returns', summary: summary, hideSpoilers: false),
        'Every tide returns',
      );
      expect(ReelPremise.line(summary: summary, hideSpoilers: false), 'A ferry pilot finds a letter in the hold.');
      expect(ReelPremise.line(tagline: '  ', summary: '', hideSpoilers: false), isNull);
    });

    test("the app's spoiler setting hides an unwatched episode's text, never a title's premise", () {
      const summary = 'Two sisters reopen the harbor lights.';
      expect(ReelPremise.line(summary: summary, hideSpoilers: true, unwatchedEpisode: true), isNull);
      expect(ReelPremise.line(summary: summary, hideSpoilers: false, unwatchedEpisode: true), summary);
      expect(ReelPremise.line(summary: summary, hideSpoilers: true), summary);
    });

    test('a stop after a title or an initial does not end the sentence', () {
      expect(
        ReelPremise.firstSentence('Dr. Vale and J. Moss chart the reef. A storm comes.'),
        'Dr. Vale and J. Moss chart the reef.',
      );
      expect(ReelPremise.firstSentence('No stop at all'), 'No stop at all');
      expect(ReelPremise.firstSentence('"Run!" she says. They run.'), '"Run!" she says.');
    });
  });

  group("the build's source text", () {
    test('the tagline and the first two sentences of the summary, capped', () {
      expect(
        ReelPremise.source(tagline: 'Every tide returns', summary: 'One. Two two. Three three three.'),
        'Every tide returns One. Two two.',
      );
      expect(ReelPremise.source(summary: 'Only one sentence here'), 'Only one sentence here');
      expect(ReelPremise.source(), isNull);
      final long = ReelPremise.source(summary: List.filled(120, 'word').join(' '))!;
      expect(long.length, lessThanOrEqualTo(ReelPremise.sourceChars + 1));
      expect(long, endsWith('…'));
    });
  });

  group('a hook from the build', () {
    test('is kept only with text of its own to come from, and at most 12 words', () {
      expect(
        ReelPremise.checkedHook('A keeper guards the last lighthouse', hadSource: true),
        'A keeper guards the last lighthouse',
      );
      expect(ReelPremise.checkedHook('A keeper guards the last lighthouse', hadSource: false), isNull);
      expect(ReelPremise.checkedHook(List.filled(13, 'word').join(' '), hadSource: true), isNull);
      expect(ReelPremise.checkedHook('"A quoted hook"', hadSource: true), 'A quoted hook');
      expect(ReelPremise.checkedHook('   ', hadSource: true), isNull);
    });
  });
}
