import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/continue_watching/continue_watching_classifier.dart';

import '../../test_helpers/media_items.dart';

final _now = DateTime(2026, 10, 31, 12);
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
  group('classifyContinueWatching', () {
    test('splits on the 30-day cut-off, keeping order', () {
      final split = classifyContinueWatching([
        _episode('The Rookie', offsetMs: 600000, lastViewedDaysAgo: 0.2),
        _episode('Castle', offsetMs: 900000, lastViewedDaysAgo: 29),
        _episode('Samurai Champloo', lastViewedDaysAgo: 35),
        _movie('Inception', offsetMs: 900000, lastViewedDaysAgo: 70),
      ], now: _now);

      expect(_names(split.fresh), ['The Rookie', 'Castle']);
      expect(_names(split.pickBackUp), ['Samurai Champloo', 'Inception']);
    });

    test('next-up episodes are aged by when the show was last watched', () {
      // Unstarted next episode added long ago, show watched last week: fresh.
      final split = classifyContinueWatching([_episode('Avatar', lastViewedDaysAgo: 7, addedDaysAgo: 300)], now: _now);
      expect(_names(split.fresh), ['Avatar']);
    });

    test('a new episode of a caught-up show stays fresh regardless of age', () {
      final split = classifyContinueWatching([
        _episode('Expanse', lastViewedDaysAgo: 90, addedDaysAgo: 3),
        _episode('Heroes', lastViewedDaysAgo: 90, addedDaysAgo: 400),
      ], now: _now);
      expect(_names(split.fresh), ['Expanse']);
      expect(_names(split.pickBackUp), ['Heroes']);
    });

    test('drops accidental starts under 3 minutes', () {
      final split = classifyContinueWatching([
        _episode('Modern Family', offsetMs: 128879, lastViewedDaysAgo: 0.1),
        _episode('Friends', offsetMs: 180000, lastViewedDaysAgo: 0.1),
      ], now: _now);
      expect(_names(split.fresh), ['Friends']);
      expect(split.pickBackUp, isEmpty);
    });

    test('films 90% or more through count as finished and are hidden; episodes are not', () {
      final split = classifyContinueWatching([
        _movie('Valkyrie', offsetMs: 6600000, lastViewedDaysAgo: 2),
        _movie('Inception', offsetMs: 6400000, lastViewedDaysAgo: 2),
        _episode('Dr. Stone', offsetMs: 1400000, durationMs: 1446620, lastViewedDaysAgo: 2),
      ], now: _now);
      expect(_names(split.fresh), ['Inception', 'Dr. Stone']);
    });

    test('excludes comfort shows by normalised title', () {
      final split = classifyContinueWatching(
        [
          _episode('Castle (2009)', offsetMs: 900000, lastViewedDaysAgo: 1),
          _episode('Brooklyn Nine-Nine', offsetMs: 900000, lastViewedDaysAgo: 1),
          _episode('The Orville', offsetMs: 900000, lastViewedDaysAgo: 50),
          _movie('Castle', offsetMs: 900000, lastViewedDaysAgo: 1),
        ],
        now: _now,
        excludedShowTitles: {normalizeShowTitle('Castle'), normalizeShowTitle('Brooklyn Nine-Nine')},
      );
      // Only episodes are matched against show titles; a film named "Castle" stays.
      expect(_names(split.fresh), ['Castle']);
      expect(_names(split.pickBackUp), ['The Orville']);
    });

    test('an item with no timestamps stays in the main row', () {
      final undated = testMediaItem(id: 'x', kind: MediaKind.movie, title: 'Undated');
      final split = classifyContinueWatching([undated], now: _now);
      expect(split.fresh, [undated]);
    });

    test('the cut-off is configurable', () {
      final split = classifyContinueWatching(
        [_episode('Castle', offsetMs: 900000, lastViewedDaysAgo: 10)],
        now: _now,
        staleAfter: const Duration(days: 7),
      );
      expect(split.fresh, isEmpty);
      expect(_names(split.pickBackUp), ['Castle']);
    });
  });

  group('normalizeShowTitle', () {
    test('ignores case, punctuation and a trailing year', () {
      expect(normalizeShowTitle('Castle (2009)'), normalizeShowTitle('castle'));
      expect(normalizeShowTitle('Brooklyn Nine-Nine'), 'brooklynninenine');
      expect(normalizeShowTitle(null), '');
      expect(normalizeShowTitle('1408'), '1408');
    });
  });
}
