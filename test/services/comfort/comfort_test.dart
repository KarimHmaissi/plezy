import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/comfort/comfort_list_description.dart';
import 'package:plezy/services/comfort/comfort_picker.dart';

void main() {
  group('Comfort list description', () {
    test('reads paused Trakt ids from the marker', () {
      expect(parsePausedTraktIds('Paused in Plezy: Star Relay, Island Hours [plezy:paused=trakt:1234,trakt:5678]'), {
        1234,
        5678,
      });
    });

    test('no marker or junk tokens mean nothing paused', () {
      expect(parsePausedTraktIds(null), isEmpty);
      expect(parsePausedTraktIds('My favourite shows'), isEmpty);
      expect(parsePausedTraktIds('[plezy:paused=]'), isEmpty);
      expect(parsePausedTraktIds('[plezy:paused=trakt:12,imdb:tt1,trakt:x]'), {12});
    });

    test('writing keeps the user\'s own text and appends one marker line', () {
      final written = writePausedTraktIds('Easy evening shows\nNothing too dark', {
        1234: 'Star Relay',
        5678: 'Island Hours',
      });
      expect(
        written,
        'Easy evening shows\nNothing too dark\nPaused in Plezy: Star Relay, Island Hours [plezy:paused=trakt:1234,trakt:5678]',
      );
      expect(parsePausedTraktIds(written), {1234, 5678});
    });

    test('rewriting replaces the old marker line instead of adding another', () {
      final first = writePausedTraktIds('Notes', {1: 'A'});
      final second = writePausedTraktIds(first, {2: 'B'});
      expect(second, 'Notes\nPaused in Plezy: B [plezy:paused=trakt:2]');
      expect(parsePausedTraktIds(second), {2});
    });

    test('unpausing everything removes the marker line and keeps the rest', () {
      final paused = writePausedTraktIds('Notes', {1: 'A'});
      expect(writePausedTraktIds(paused, {}), 'Notes');
      expect(writePausedTraktIds(null, {}), '');
    });

    test('brackets in show titles cannot break the marker', () {
      final written = writePausedTraktIds(null, {7: 'Show [UK]'});
      expect(parsePausedTraktIds(written), {7});
    });
  });

  group('pickComfortEpisode', () {
    test('every show gets an equal chance regardless of episode count', () async {
      final episodes = {'Flatmates': List.generate(236, (i) => 'F$i'), 'Seaside Inn': List.generate(12, (i) => 'W$i')};
      final rng = Random(42);
      final counts = <String, int>{'Flatmates': 0, 'Seaside Inn': 0};
      for (var i = 0; i < 2000; i++) {
        final pick = await pickComfortEpisode<String, String>(
          shows: const ['Flatmates', 'Seaside Inn'],
          episodesFor: (show) async => episodes[show]!,
          random: rng,
        );
        counts[pick!.show] = counts[pick.show]! + 1;
      }
      expect(counts['Flatmates']! / 2000, closeTo(0.5, 0.05));
      expect(counts['Seaside Inn']! / 2000, closeTo(0.5, 0.05));
    });

    test('skips shows with no local episodes or failing lookups', () async {
      final pick = await pickComfortEpisode<String, String>(
        shows: const ['Missing', 'Broken', 'Office'],
        episodesFor: (show) async => switch (show) {
          'Missing' => const [],
          'Broken' => throw Exception('server down'),
          _ => const ['O1'],
        },
        random: Random(1),
      );
      expect(pick, (show: 'Office', episode: 'O1'));
    });

    test('prefers episodes not watched recently, then shows with fresh episodes', () async {
      for (var seed = 0; seed < 20; seed++) {
        final pick = await pickComfortEpisode<String, String>(
          shows: const ['AllWatched', 'Office'],
          episodesFor: (show) async => show == 'AllWatched' ? const ['A1', 'A2'] : const ['O1', 'O2-recent'],
          isRecentlyWatched: (e) => e == 'A1' || e == 'A2' || e == 'O2-recent',
          random: Random(seed),
        );
        expect(pick, (show: 'Office', episode: 'O1'));
      }
    });

    test('falls back to a recently watched episode rather than nothing', () async {
      final pick = await pickComfortEpisode<String, String>(
        shows: const ['Office'],
        episodesFor: (_) async => const ['O1'],
        isRecentlyWatched: (_) => true,
      );
      expect(pick, (show: 'Office', episode: 'O1'));
    });

    test('returns null when nothing is playable', () async {
      expect(await pickComfortEpisode<String, String>(shows: const [], episodesFor: (_) async => const []), isNull);
      expect(await pickComfortEpisode<String, String>(shows: const ['A'], episodesFor: (_) async => const []), isNull);
    });

    test('fetches episodes lazily, one show at a time', () async {
      final fetched = <String>[];
      await pickComfortEpisode<String, String>(
        shows: const ['A', 'B', 'C'],
        episodesFor: (show) async {
          fetched.add(show);
          return const ['E'];
        },
      );
      expect(fetched, hasLength(1));
    });
  });

  group('watchedWithin', () {
    final now = DateTime(2026, 10, 31);
    int secondsAgo(Duration d) => now.subtract(d).millisecondsSinceEpoch ~/ 1000;

    test('true inside the window, false outside or never watched', () {
      expect(watchedWithin(secondsAgo(const Duration(days: 3)), comfortRecentlyWatchedWindow, now: now), isTrue);
      expect(watchedWithin(secondsAgo(const Duration(days: 45)), comfortRecentlyWatchedWindow, now: now), isFalse);
      expect(watchedWithin(null, comfortRecentlyWatchedWindow, now: now), isFalse);
    });
  });
}
