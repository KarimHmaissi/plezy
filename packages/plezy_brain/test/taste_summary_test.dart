import 'package:plezy_brain/plezy_brain.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 6, 1);
  DateTime ago(int days) => now.subtract(Duration(days: days));

  test('taste summary lists recent, loved and dropped titles with genres', () {
    final text = tasteSummary([
      TitleProfile(id: 'a', kind: TitleKind.movie, title: 'Alpha', year: 2020, genres: ['Thriller'], watches: [ago(3)]),
      TitleProfile(
        id: 'b',
        kind: TitleKind.movie,
        title: 'Beta',
        year: 2001,
        genres: ['Drama'],
        watches: [ago(900)],
        myRating: 9,
      ),
      TitleProfile(
        id: 'c',
        kind: TitleKind.show,
        title: 'Gamma',
        genres: ['Thriller'],
        watches: [for (var i = 0; i < 4; i++) ago(400 + i)],
        episodesWatched: 4,
        episodeCount: 40,
      ),
    ], now: now);

    expect(text, contains('- Alpha (2020), film, 2026-05'));
    expect(text, contains('Gamma, show, 2025-04, dropped (4/40 eps)'));
    expect(text, contains("Didn't stick (dropped, only sampled, or rated 4 or less): Gamma."));
    expect(text, contains('Top genres, last 12 months (titles): Thriller 1.'));
    // Beta is in the recent list (it's one of the last 25), so not repeated as loved.
    expect(text, isNot(contains('Loved')));
  });

  test('no history, no summary', () => expect(tasteSummary(const [], now: now), isEmpty));
}
