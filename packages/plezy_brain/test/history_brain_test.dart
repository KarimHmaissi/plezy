import 'dart:typed_data';

import 'package:plezy_brain/plezy_brain.dart';
import 'package:test/test.dart';

/// Hashes words into a small vector: texts sharing words point the same way.
class _BagOfWords implements Embedder {
  int calls = 0;

  @override
  String get modelId => 'bag';
  @override
  int get dimensions => 16;

  @override
  Future<List<Float32List>> embed(List<String> texts, {bool query = false}) async {
    calls++;
    return [
      for (final t in texts)
        normalise([
          for (var i = 0; i < dimensions; i++)
            t.toLowerCase().split(RegExp(r'\W+')).where((w) => w.length > 3 && w.hashCode % dimensions == i).length +
                0.01,
        ]),
    ];
  }
}

TitleProfile _film(String id, String title, {String summary = '', List<DateTime> watches = const [], int bulk = 0}) =>
    TitleProfile(
      id: id,
      kind: TitleKind.movie,
      title: title,
      summary: summary,
      genres: const ['Crime'],
      watches: watches,
      bulkPlays: bulk,
    );

void main() {
  group('WordPieceTokenizer', () {
    final t = WordPieceTokenizer({
      '[PAD]': 0,
      '[UNK]': 1,
      '[CLS]': 2,
      '[SEP]': 3,
      'heist': 4,
      'film': 5,
      '##s': 6,
      'cafe': 7,
      '!': 8,
      'un': 9,
      '##believ': 10,
      '##able': 11,
    }, maxLength: 6);

    test('lowercases, strips accents, splits punctuation and sub-words', () {
      expect(t.encode('Heist FILMS!'), [2, 4, 5, 6, 8, 3]);
      expect(WordPieceTokenizer(t.vocab).encode('Café unbelievable xyz'), [2, 7, 9, 10, 11, 1, 3]);
    });

    test('truncates to maxLength and pads a batch', () {
      expect(t.encode('heist heist heist heist heist heist'), hasLength(6));
      final b = t.batch(['heist', 'heist film']);
      expect((b.rows, b.length), (2, 4));
      expect(b.ids, [2, 4, 3, 0, 2, 4, 5, 3]);
      expect(b.mask, [1, 1, 1, 0, 1, 1, 1, 1]);
    });
  });

  test('TransformerEmbedder pools the CLS token and normalises', () async {
    final e = TransformerEmbedder(
      modelId: 'm',
      dimensions: 2,
      tokenizer: WordPieceTokenizer({'[PAD]': 0, '[UNK]': 1, '[CLS]': 2, '[SEP]': 3}),
      run: (b) async => Float32List.fromList([
        for (var r = 0; r < b.rows; r++)
          for (var i = 0; i < b.length; i++) ...(i == 0 ? [3.0, 4.0] : [9.0, 9.0]),
      ]),
      queryPrefix: 'q: ',
    );
    final v = (await e.embed(['a', 'b c']));
    expect(v, hasLength(2));
    expect(v.first[0], closeTo(0.6, 1e-6));
    expect(v.first[1], closeTo(0.8, 1e-6));
  });

  group('BrainStore and BrainIndexer', () {
    late BrainStore store;
    setUp(() => store = BrainStore.memory());
    tearDown(() => store.close());

    test('indexes only what changed and finds similar titles', () async {
      final heist = _film(
        'a',
        'Bank Job',
        summary: 'A crew plans a daring bank heist robbery',
        watches: [DateTime(2024)],
      );
      final heist2 = _film('b', 'Vault', summary: 'Thieves attempt a heist robbery of a vault');
      final space = _film('c', 'Orbit', summary: 'Astronauts stranded aboard a failing space station');
      expect(store.putProfiles([heist, heist2, space]), 3);
      expect(store.putProfiles([heist, heist2, space]), 0, reason: 'unchanged profiles are skipped');

      final embedder = _BagOfWords();
      final first = await BrainIndexer(store: store, embedder: embedder, batchSize: 2).run();
      expect((first.embedded, first.remaining), (3, 0));
      expect((await BrainIndexer(store: store, embedder: embedder).run()).embedded, 0);

      // A new watch changes the profile but not its text: no re-embedding.
      store.putProfiles([
        _film('b', 'Vault', summary: heist2.summary!, watches: [DateTime(2025)]),
      ]);
      expect(store.pendingVectors('bag'), 0);
      expect(store.counts('bag'), (profiles: 3, watched: 2, vectors: 3));

      expect(store.similar('bag', 'a', limit: 1).single.id, 'b');
      final q = (await embedder.embed(['heist robbery'], query: true)).single;
      expect(store.search('bag', q, limit: 1).single.id, anyOf('a', 'b'));
      expect(store.search('bag', q, watched: false).map((h) => h.id), ['c']);

      expect(store.removeProfilesExcept({'a', 'b'}), 1);
      expect(store.search('bag', q).map((h) => h.id), isNot(contains('c')));
    });

    test('a background run rests in proportion to the work, longer when batches slow down', () {
      final indexer = BrainIndexer(store: store, embedder: _BagOfWords(), duty: 0.25);
      expect(indexer.restAfter(const Duration(seconds: 1), 10), const Duration(seconds: 3));
      // Twice as slow per title as the best seen: twice the rest again.
      expect(indexer.restAfter(const Duration(seconds: 2), 10), const Duration(seconds: 12));
      expect(
        BrainIndexer(store: store, embedder: _BagOfWords()).restAfter(const Duration(seconds: 1), 10),
        Duration.zero,
      );
    });

    test('waits while paused', () async {
      store.putProfiles([_film('a', 'A')]);
      var pauses = 2;
      final sleeps = <Duration>[];
      await BrainIndexer(
        store: store,
        embedder: _BagOfWords(),
        shouldPause: () => pauses-- > 0,
        sleep: (d) async => sleeps.add(d),
      ).run();
      expect(sleeps, [BrainIndexer.pausePoll, BrainIndexer.pausePoll]);
    });
  });

  group('HistoryQuery', () {
    final now = DateTime.utc(2026, 6, 1);
    final films = [
      _film('a', 'Heist One', watches: [DateTime.utc(2025, 7, 10)]),
      _film('b', 'Heist Two', watches: [DateTime.utc(2024, 1, 1), DateTime.utc(2025, 8, 1)]),
      _film('c', 'Imported', bulk: 1),
    ];
    final shows = [
      TitleProfile(
        id: 's1',
        kind: TitleKind.show,
        title: 'Dropped',
        watches: [DateTime.utc(2025, 1, 1), DateTime.utc(2025, 1, 2), DateTime.utc(2025, 1, 3)],
        episodesWatched: 3,
        episodeCount: 10,
      ),
      TitleProfile(
        id: 's2',
        kind: TitleKind.show,
        title: 'Current',
        watches: [DateTime.utc(2026, 5, 30)],
        episodesWatched: 1,
        episodeCount: 8,
      ),
      TitleProfile(
        id: 's3',
        kind: TitleKind.show,
        title: 'Done',
        watches: [DateTime.utc(2024, 3, 1)],
        episodesWatched: 9,
        episodeCount: 10,
      ),
    ];
    final all = [...films, ...shows];

    test('filters by date range, rewatches and show progress', () {
      final summer = HistoryQuery(watchedFrom: DateTime.utc(2025, 6), watchedTo: DateTime.utc(2025, 9));
      expect(summer.run(all, now: now).map((p) => p.id), ['b', 'a']);
      expect(const HistoryQuery(rewatched: true).run(all, now: now).map((p) => p.id), ['b']);
      expect(const HistoryQuery(progress: {ShowProgress.dropped}).run(all, now: now).map((p) => p.id), ['s1']);
      expect(shows.map((s) => s.progress(now)), [ShowProgress.dropped, ShowProgress.inProgress, ShowProgress.finished]);
      TitleProfile show(DateTime last, int watched) => TitleProfile(
        id: 'x',
        kind: TitleKind.show,
        title: 'X',
        watches: [last],
        episodesWatched: watched,
        episodeCount: 40,
      );
      expect(show(DateTime.utc(2026, 2, 1), 10).progress(now), ShowProgress.paused);
      expect(show(DateTime.utc(2024, 1, 1), 2).progress(now), ShowProgress.sampled);
      expect(show(DateTime.utc(2024, 1, 1), 4).progress(now), ShowProgress.dropped);
      expect(show(DateTime.utc(2024, 1, 1), 38).progress(now), ShowProgress.finished, reason: 'caught up');
      expect(const HistoryQuery().run(all, now: now).map((p) => p.id), contains('c'), reason: 'imports count');
    });

    test('counts by year (undated apart) and by kind', () {
      final byYear = historyStats(all, const HistoryQuery(), HistoryGroup.year, now: now);
      expect([for (final r in byYear) (r.group, r.plays)], [('undated', 1), ('2026', 1), ('2025', 5), ('2024', 2)]);
      final inRange = historyStats(
        all,
        HistoryQuery(watchedFrom: DateTime.utc(2025), watchedTo: DateTime.utc(2026)),
        HistoryGroup.kind,
        now: now,
      );
      expect([for (final r in inRange) (r.group, r.titles, r.plays)], [('film', 2, 2), ('show', 1, 3)]);
    });
  });

  test('profiles round-trip through JSON', () {
    final p = TitleProfile(
      id: 's:tvdb:1',
      kind: TitleKind.show,
      title: 'T',
      year: 2001,
      genres: const ['Drama'],
      cast: const ['A', 'B'],
      watches: [DateTime.utc(2020)],
      episodesWatched: 3,
      episodeCount: 10,
      myRating: 8,
      comfort: true,
    );
    final back = TitleProfile.fromJson(p.toJson());
    expect(back.toJson(), p.toJson());
    expect(back.embedText, contains('TV series'));
    expect(back.embedText, isNot(contains('2020')), reason: 'watch data stays out of the embedding');
  });
}
