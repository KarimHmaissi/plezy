import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/continue_watching/continue_watching_classifier.dart';

import '../../test_helpers/media_items.dart';

final _now = DateTime(2026, 1, 15, 12);
int _daysAgo(num days) => _now.subtract(Duration(minutes: (days * 24 * 60).round())).millisecondsSinceEpoch ~/ 1000;

MediaItem _episode(
  String show, {
  int? offsetMs,
  int durationMs = 1500000,
  required num lastViewedDaysAgo,
  num addedDaysAgo = 400,
}) => testMediaItem(
  id: '$show-ep',
  kind: MediaKind.episode,
  title: 'Episode',
  grandparentTitle: show,
  durationMs: durationMs,
  viewOffsetMs: offsetMs,
).copyWith(lastViewedAt: _daysAgo(lastViewedDaysAgo), addedAt: _daysAgo(addedDaysAgo));

MediaItem _movie(String title, {required int offsetMs, int durationMs = 7200000, required num lastViewedDaysAgo}) =>
    testMediaItem(
      id: title,
      kind: MediaKind.movie,
      title: title,
      durationMs: durationMs,
      viewOffsetMs: offsetMs,
    ).copyWith(lastViewedAt: _daysAgo(lastViewedDaysAgo), addedAt: _daysAgo(500));

List<String> _names(List<MediaItem> items) => [for (final i in items) i.grandparentTitle ?? i.title ?? ''];

void main() {
  group('comfortCarryOn', () {
    test('part-watched comfort episodes, newest first; others, starts and near-finishes left out', () {
      final comfort = {
        normalizeShowTitle('Quiet Harbour'),
        normalizeShowTitle('Flatmates'),
        normalizeShowTitle('Marsh Lane (2009)'),
      };
      final items = comfortCarryOn([
        _episode('Quiet Harbour', offsetMs: 600000, lastViewedDaysAgo: 3),
        _episode('Flatmates', offsetMs: 900000, lastViewedDaysAgo: 1),
        _episode('Marsh Lane', offsetMs: 300000, lastViewedDaysAgo: 2),
        _episode('Ordinary Powers', offsetMs: 600000, lastViewedDaysAgo: 0), // not a comfort show
        _episode('Corner Diner', offsetMs: 600000, lastViewedDaysAgo: 0),
        _episode('Quiet Harbour', offsetMs: 60000, lastViewedDaysAgo: 0).copyWith(id: 'start'), // 1 min in
        _episode('Flatmates', offsetMs: 1450000, lastViewedDaysAgo: 0).copyWith(id: 'nearly'), // 97%
        _episode('Flatmates', lastViewedDaysAgo: 0).copyWith(id: 'next'), // next episode, unstarted
        _movie('Flatmates', offsetMs: 600000, lastViewedDaysAgo: 0),
      ], comfort);
      expect(_names(items), ['Flatmates', 'Marsh Lane', 'Quiet Harbour']);
    });

    test('no comfort shows, no row', () {
      expect(comfortCarryOn([_episode('Quiet Harbour', offsetMs: 600000, lastViewedDaysAgo: 1)], const {}), isEmpty);
    });
  });

  group('classifyContinueWatching', () {
    test('splits on the 30-day cut-off, keeping order', () {
      final split = classifyContinueWatching([
        _episode('Night Patrol', offsetMs: 600000, lastViewedDaysAgo: 0.2),
        _episode('Marsh Lane', offsetMs: 900000, lastViewedDaysAgo: 29),
        _episode('Paper Lantern Road', lastViewedDaysAgo: 35),
        _movie('Dream Vault', offsetMs: 900000, lastViewedDaysAgo: 70),
      ], now: _now);

      expect(_names(split.fresh), ['Night Patrol', 'Marsh Lane']);
      expect(_names(split.pickBackUp), ['Paper Lantern Road', 'Dream Vault']);
    });

    test('next-up episodes are aged by when the show was last watched', () {
      // Unstarted next episode added long ago, show watched last week: fresh.
      final split = classifyContinueWatching([
        _episode('Sky Tribe', lastViewedDaysAgo: 7, addedDaysAgo: 300),
      ], now: _now);
      expect(_names(split.fresh), ['Sky Tribe']);
    });

    test('a new episode of a caught-up show stays fresh regardless of age', () {
      final split = classifyContinueWatching([
        _episode('Distant Orbit', lastViewedDaysAgo: 90, addedDaysAgo: 3),
        _episode('Ordinary Powers', lastViewedDaysAgo: 90, addedDaysAgo: 400),
      ], now: _now);
      expect(_names(split.fresh), ['Distant Orbit']);
      expect(_names(split.pickBackUp), ['Ordinary Powers']);
    });

    test('drops accidental starts under 3 minutes', () {
      final split = classifyContinueWatching([
        _episode('Suburb Life', offsetMs: 128000, lastViewedDaysAgo: 0.1),
        _episode('Flatmates', offsetMs: 180000, lastViewedDaysAgo: 0.1),
      ], now: _now);
      expect(_names(split.fresh), ['Flatmates']);
      expect(split.pickBackUp, isEmpty);
    });

    test('films 90% or more through count as finished and are hidden; episodes are not', () {
      final split = classifyContinueWatching([
        _movie('Last Briefing', offsetMs: 6600000, lastViewedDaysAgo: 2),
        _movie('Dream Vault', offsetMs: 6400000, lastViewedDaysAgo: 2),
        _episode('Stone Age Lab', offsetMs: 1400000, durationMs: 1440000, lastViewedDaysAgo: 2),
      ], now: _now);
      expect(_names(split.fresh), ['Dream Vault', 'Stone Age Lab']);
    });

    test('excludes comfort shows by normalised title', () {
      final split = classifyContinueWatching(
        [
          _episode('Marsh Lane (2009)', offsetMs: 900000, lastViewedDaysAgo: 1),
          _episode('Precinct Nine-Nine', offsetMs: 900000, lastViewedDaysAgo: 1),
          _episode('Star Freighter', offsetMs: 900000, lastViewedDaysAgo: 50),
          _movie('Marsh Lane', offsetMs: 900000, lastViewedDaysAgo: 1),
        ],
        now: _now,
        excludedShowTitles: {normalizeShowTitle('Marsh Lane'), normalizeShowTitle('Precinct Nine-Nine')},
      );
      // Only episodes are matched against show titles; a film named "Marsh Lane" stays.
      expect(_names(split.fresh), ['Marsh Lane']);
      expect(_names(split.pickBackUp), ['Star Freighter']);
    });

    test('drops items older than the 365-day limit but keeps new episodes', () {
      final split = classifyContinueWatching([
        _movie('Metal Suit', offsetMs: 3800000, lastViewedDaysAgo: 354),
        _movie('Hero League: Finale', offsetMs: 1350000, lastViewedDaysAgo: 700),
        _episode('Old Show', lastViewedDaysAgo: 500, addedDaysAgo: 2),
      ], now: _now);
      expect(_names(split.fresh), ['Old Show']);
      expect(_names(split.pickBackUp), ['Metal Suit']);
    });

    test('an item with no timestamps stays in the main row', () {
      final undated = testMediaItem(id: 'x', kind: MediaKind.movie, title: 'Undated');
      final split = classifyContinueWatching([undated], now: _now);
      expect(split.fresh, [undated]);
    });

    test('the cut-off is configurable', () {
      final split = classifyContinueWatching(
        [_episode('Marsh Lane', offsetMs: 900000, lastViewedDaysAgo: 10)],
        now: _now,
        staleAfter: const Duration(days: 7),
      );
      expect(split.fresh, isEmpty);
      expect(_names(split.pickBackUp), ['Marsh Lane']);
    });
  });

  group('normalizeShowTitle', () {
    test('ignores case, punctuation and a trailing year', () {
      expect(normalizeShowTitle('Marsh Lane (2009)'), normalizeShowTitle('marsh lane'));
      expect(normalizeShowTitle('Precinct Nine-Nine'), 'precinctninenine');
      expect(normalizeShowTitle(null), '');
      expect(normalizeShowTitle('1408'), '1408');
    });
  });
}
