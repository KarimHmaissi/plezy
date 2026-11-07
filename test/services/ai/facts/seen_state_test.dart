import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/ai/ai_watch_state.dart';
import 'package:plezy/services/ai/facts/seen_state.dart';
import 'package:plezy_brain/plezy_brain.dart';

final _now = DateTime.utc(2026, 11, 6);

TitleProfile _film({List<DateTime> watches = const [], int bulk = 0, Set<String> via = const {}}) => TitleProfile(
  id: 'm:imdb:tt1',
  kind: TitleKind.movie,
  title: 'Film',
  watches: watches,
  bulkPlays: bulk,
  bulkVia: via,
);

TitleProfile _show({required int eps, int? total, DateTime? last, int bulk = 0}) => TitleProfile(
  id: 's:tvdb:1',
  kind: TitleKind.show,
  title: 'Show',
  watches: [?last],
  bulkPlays: bulk,
  episodesWatched: eps,
  episodeCount: total,
);

void main() {
  group('films', () {
    test('no plays anywhere is unseen, and only that is unseen', () {
      final s = SeenState.of(row: const WatchState(), profile: _film(), now: _now);
      expect(s.kind, SeenKind.unseen);
      expect(s.isUnseen, isTrue);
      expect(s.badge, isNull);
      expect(s.line(), 'unseen');
    });

    test('a real watch is dated', () {
      final s = SeenState.of(
        profile: _film(watches: [DateTime.utc(2026, 10, 3)]),
        now: _now,
      );
      expect(s.kind, SeenKind.watched);
      expect(s.line(), 'watched Oct 2026');
      expect(s.badge, 'Seen');
    });

    test('Trakt-logged titles are seen, never unwatched', () {
      final s = SeenState.of(
        row: const WatchState(),
        profile: _film(bulk: 1, via: {'trakt'}),
        now: _now,
      );
      expect(s.kind, SeenKind.logged);
      expect(s.isUnseen, isFalse);
      expect(s.line(), 'logged as seen (Trakt)');
      expect(s.badge, 'Seen');
    });

    test('a Plex mark says so', () {
      final s = SeenState.of(
        profile: _film(bulk: 1, via: {'plexUndated'}),
        now: _now,
      );
      expect(s.line(), 'marked watched (Plex)');
    });

    test('a Plex play count with no brain is logged by Plex, not "no record"', () {
      final s = SeenState.of(row: const WatchState(seen: true), now: _now);
      expect(s.kind, SeenKind.logged);
      expect(s.line(), 'marked watched (Plex)');
    });

    test('a profile built before sources were kept still reads as logged', () {
      final s = SeenState.of(profile: _film(bulk: 1), now: _now);
      expect(s.line(), 'logged as seen');
    });

    test('a film stopped partway is in progress and not unseen', () {
      final s = SeenState.of(row: const WatchState(inProgress: true), profile: _film(), now: _now);
      expect(s.kind, SeenKind.inProgress);
      expect(s.isUnseen, isFalse);
      expect(s.badge, 'Watching');
    });

    test('a rewatch is noted', () {
      final s = SeenState.of(
        profile: _film(watches: [DateTime.utc(2024), DateTime.utc(2026, 3)]),
        now: _now,
      );
      expect(s.line(), 'watched Mar 2026, rewatched');
    });
  });

  group('shows', () {
    test('watching lately', () {
      final s = SeenState.of(
        profile: _show(eps: 38, total: 62, last: DateTime.utc(2026, 10, 30)),
        now: _now,
      );
      expect(s.kind, SeenKind.inProgress);
      expect(s.line(), '38/62 eps, watching');
      expect(s.badge, 'Watching');
    });

    test('one episode long ago is sampled', () {
      final s = SeenState.of(
        profile: _show(eps: 1, total: 59, last: DateTime.utc(2024)),
        now: _now,
      );
      expect(s.line(), '1/59 eps, sampled');
      expect(s.badge, 'Started');
    });

    test('caught up is finished', () {
      final s = SeenState.of(
        profile: _show(eps: 62, total: 62, last: DateTime.utc(2025)),
        now: _now,
      );
      expect(s.kind, SeenKind.finished);
      expect(s.badge, 'Seen');
    });

    test('the row and the brain merge: the larger episode count wins', () {
      final s = SeenState.of(
        row: const WatchState(isShow: true, seen: true, episodesWatched: 40, episodeCount: 62),
        profile: _show(eps: 38, total: 62, last: DateTime.utc(2026, 10, 30)),
        now: _now,
      );
      expect(s.line(), '40/62 eps, watching');
    });

    test('Plex-only episodes with no brain', () {
      final s = SeenState.of(
        row: const WatchState(isShow: true, seen: true, episodesWatched: 10, episodeCount: 10),
        now: _now,
      );
      expect(s.kind, SeenKind.finished);
    });

    test('an untouched show is unseen', () {
      final s = SeenState.of(row: const WatchState(isShow: true, episodeCount: 10), now: _now);
      expect(s.isUnseen, isTrue);
    });
  });
}
