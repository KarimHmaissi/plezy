import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/library_index/index_search.dart';
import 'package:plezy/services/library_index/library_index.dart';

Map<String, dynamic> _movie(
  String key,
  String title, {
  int year = 2000,
  double? rating,
  List<String> genres = const [],
  String? imdb,
  int minutes = 100,
  int? viewCount,
  String summary = '',
  List<String> cast = const [],
  int addedAt = 1000,
}) => {
  'ratingKey': key,
  'type': 'movie',
  'title': title,
  'year': year,
  'originallyAvailableAt': '$year-06-01',
  'audienceRating': ?rating,
  'duration': minutes * 60000,
  'summary': summary,
  'addedAt': addedAt,
  'updatedAt': addedAt,
  'viewCount': ?viewCount,
  'Genre': [
    for (final g in genres) {'tag': g},
  ],
  'Role': [
    for (final c in cast) {'tag': c},
  ],
  'Guid': [
    if (imdb != null) {'id': 'imdb://$imdb'},
  ],
};

/// A Plex server in memory; [failAfter] simulates the app closing mid-build.
class _FakeSource implements IndexSource {
  _FakeSource(this.serverId, this.libraries);

  @override
  final String serverId;
  @override
  String get serverName => serverId;
  final Map<String, ({String title, String type, List<Map<String, dynamic>> items})> libraries;
  int requests = 0;
  int? failAfter;
  final List<Map<String, String>> filtersSeen = [];

  void _count() {
    requests++;
    if (failAfter != null && requests > failAfter!) throw StateError('connection lost');
  }

  @override
  Future<List<Map<String, dynamic>>> sections() async {
    _count();
    return [
      for (final e in libraries.entries) {'key': e.key, 'title': e.value.title, 'type': e.value.type},
      {'key': '99', 'title': 'Music', 'type': 'artist'},
    ];
  }

  @override
  Future<({List<Map<String, dynamic>> items, int total})> page(
    String sectionKey, {
    required int plexType,
    required int start,
    required int size,
    Map<String, String> filters = const {},
  }) async {
    _count();
    filtersSeen.add(filters);
    var items = libraries[sectionKey]!.items;
    for (final MapEntry(:key, :value) in filters.entries) {
      final field = key.replaceAll('>>', '');
      items = [
        for (final i in items)
          if ((i[field] as int? ?? 0) >= int.parse(value)) i,
      ];
    }
    return (items: items.skip(start).take(size).toList(), total: items.length);
  }
}

void main() {
  late IndexDatabase db;
  late LibraryIndex index;

  setUp(() {
    db = IndexDatabase.memory();
    index = LibraryIndex(openDatabase: Future.value(db), requestGap: Duration.zero);
  });
  tearDown(() => db.close());

  final films = [
    for (var i = 0; i < 1200; i++) _movie('m$i', 'Filler $i', rating: 5.0, year: 1990 + i % 30),
    _movie(
      'heat',
      'Heat',
      year: 1995,
      rating: 8.3,
      genres: ['Crime', 'Thriller'],
      imdb: 'tt0113277',
      minutes: 170,
      summary: 'A group of professional bank robbers start to feel the heat from police.',
      cast: ['Al Pacino', 'Robert De Niro'],
    ),
    _movie(
      'ocean',
      "Ocean's Eleven",
      year: 2001,
      rating: 7.7,
      genres: ['Crime', 'Comedy'],
      imdb: 'tt0240772',
      minutes: 116,
      summary: 'Danny Ocean gathers a crew to rob three Las Vegas casinos in one heist.',
      cast: ['George Clooney'],
      viewCount: 1,
    ),
  ];

  test('a full build pages through every movie and show library, skipping others', () async {
    final source = _FakeSource('srv', {'1': (title: 'Movies', type: 'movie', items: films)});
    await index.build([source]);
    final summary = await index.summary();
    expect(summary.movies, 1202);
    expect(summary.libraries.single.lastFullBuildAt, isNotNull);
    expect(source.requests, 1 + 3, reason: 'sections + 3 pages of 500');
  });

  test('an interrupted build resumes where it stopped', () async {
    final source = _FakeSource('srv', {'1': (title: 'Movies', type: 'movie', items: films)})..failAfter = 2;
    await expectLater(index.build([source]), throwsStateError);
    expect((await index.summary()).movies, 500);

    source
      ..failAfter = null
      ..requests = 0;
    await index.build([source]);
    expect((await index.summary()).movies, 1202);
    expect(source.requests, 1 + 2, reason: 'sections + the 2 remaining pages');
  });

  test('updates fetch only what was added or changed since the last check', () async {
    final source = _FakeSource('srv', {
      '1': (title: 'Movies', type: 'movie', items: [...films]),
    });
    await index.build([source]);
    source.libraries['1']!.items.add(
      _movie('new', 'Brand New Film', addedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000),
    );
    source.filtersSeen.clear();
    await index.update([source]);
    expect((await index.summary()).movies, 1203);
    expect(source.filtersSeen.map((f) => f.keys.single), ['addedAt>>', 'updatedAt>>']);
  });

  test('structured search: genres, years, length, watch state, rating order', () async {
    await index.build([
      _FakeSource('srv', {'1': (title: 'Movies', type: 'movie', items: films)}),
    ]);
    final crime = await index.search(const IndexQuery(type: 'movie', genresAll: ['crime'], limit: 5));
    expect(crime.map((t) => t.title), ['Heat', "Ocean's Eleven"]);

    final shortUnwatched90s = await index.search(
      const IndexQuery(
        genresAll: ['Crime'],
        yearFrom: 1990,
        yearTo: 1999,
        maxMinutes: 180,
        watch: IndexWatchFilter.unwatched,
      ),
    );
    expect(shortUnwatched90s.map((t) => t.title), ['Heat']);

    final notComedy = await index.search(const IndexQuery(genresAll: ['Crime'], genresNone: ['Comedy']));
    expect(notComedy.map((t) => t.title), ['Heat']);
  });

  test('full-text search finds plot words and cast', () async {
    await index.build([
      _FakeSource('srv', {'1': (title: 'Movies', type: 'movie', items: films)}),
    ]);
    expect((await index.textSearch('casino heist')).map((t) => t.title), ["Ocean's Eleven"]);
    expect((await index.textSearch('De Niro')).map((t) => t.title), ['Heat']);
  });

  test('the same film in 4K and on a second server is one result with three copies', () async {
    final heat = films.firstWhere((f) => f['ratingKey'] == 'heat');
    await index.build([
      _FakeSource('main', {
        '1': (title: 'Movies', type: 'movie', items: [heat]),
        '2': (
          title: 'Movies (4K)',
          type: 'movie',
          items: [
            {...heat, 'ratingKey': 'heat4k'},
          ],
        ),
      }),
      _FakeSource('xtra', {
        '7': (title: 'Movies', type: 'movie', items: [heat]),
      }),
    ]);
    final results = await index.search(const IndexQuery(genresAll: ['Crime']));
    expect(results, hasLength(1));
    expect(await index.copiesOf(results.single.groupKey), hasLength(3));
  });
}
