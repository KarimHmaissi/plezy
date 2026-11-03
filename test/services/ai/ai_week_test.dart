import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/ai/ai_week.dart';
import 'package:plezy_brain/plezy_brain.dart';

void main() {
  // Monday 26 October to Sunday 1 November 2026.
  final monday = DateTime(2026, 10, 26);
  DateTime day(int d, [int hour = 21]) => DateTime(2026, 10, 26 + d, hour);

  group('WatchWeek.shownOn', () {
    test('Sunday shows the week ending today', () {
      expect(WatchWeek.shownOn(DateTime(2026, 11, 1, 20)), monday);
    });

    test('Monday and Tuesday show the week just gone', () {
      expect(WatchWeek.shownOn(DateTime(2026, 11, 2, 9)), monday);
      expect(WatchWeek.shownOn(DateTime(2026, 11, 3, 23)), monday);
    });

    test('Other days show nothing', () {
      for (final d in [4, 5, 6, 7]) {
        expect(WatchWeek.shownOn(DateTime(2026, 11, d, 12)), isNull);
      }
    });
  });

  group('WatchWeek.of', () {
    final now = DateTime(2026, 11, 2, 9);

    test('counts the week only, finds finished, started and the big night', () {
      final profiles = [
        TitleProfile(
          id: 'm:1',
          kind: TitleKind.movie,
          title: 'The Lantern Keeper',
          runtimeMinutes: 100,
          genres: const ['Drama'],
          watches: [day(3), day(-10)],
        ),
        TitleProfile(
          id: 's:1',
          kind: TitleKind.show,
          title: 'Harbour Lights',
          runtimeMinutes: 30,
          genres: const ['Comedy'],
          episodeCount: 10,
          episodesWatched: 10,
          watches: [for (var i = 0; i < 6; i++) day(3, 18 + i % 4), day(-30)],
        ),
        TitleProfile(
          id: 's:2',
          kind: TitleKind.show,
          title: 'Paper Moons',
          runtimeMinutes: 45,
          genres: const ['Sci-Fi'],
          episodeCount: 8,
          episodesWatched: 2,
          watches: [day(0), day(5)],
        ),
        TitleProfile(id: 'm:2', kind: TitleKind.movie, title: 'Last Summer', runtimeMinutes: 90, watches: [day(-3)]),
      ];
      final week = WatchWeek.of(profiles, monday, now: now)!;
      expect(week.films, 1);
      expect(week.episodes, 8);
      expect(week.minutes, 100 + 6 * 30 + 2 * 45);
      expect(week.top.map((p) => p.title), ['Harbour Lights', 'The Lantern Keeper', 'Paper Moons']);
      expect(week.finished.map((p) => p.title), ['Harbour Lights']);
      expect(week.started.map((p) => p.title), ['Paper Moons']);
      expect(week.bigNight, DateTime.thursday);
      expect(week.topGenre, 'Comedy');
    });

    test('nothing watched in the week gives no card', () {
      final profiles = [
        TitleProfile(id: 'm:2', kind: TitleKind.movie, title: 'Last Summer', watches: [day(-3)]),
      ];
      expect(WatchWeek.of(profiles, monday, now: now), isNull);
    });

    test('no pattern when watching was spread out', () {
      final profiles = [
        for (var d = 0; d < 7; d++)
          TitleProfile(id: 'm:$d', kind: TitleKind.movie, title: 'Film $d', runtimeMinutes: 100, watches: [day(d)]),
      ];
      expect(WatchWeek.of(profiles, monday, now: now)!.bigNight, isNull);
    });
  });
}
