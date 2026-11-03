import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/ai/ai_suggestions.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/library_index/index_mapping.dart';
import 'package:plezy/services/library_index/library_index.dart';

void main() {
  late IndexDatabase db;
  late LibraryIndex index;

  Future<void> add(String key, String title, String genre, {String summary = '', int views = 0}) => db
      .into(db.indexTitles)
      .insert(
        indexRowFromPlex(
          {
            'ratingKey': key,
            'type': 'movie',
            'title': title,
            'year': 1990,
            'summary': summary,
            'viewCount': views,
            'Genre': [
              {'tag': genre},
            ],
          },
          serverId: 's',
          serverName: 'S',
          libraryKey: '1',
          libraryTitle: 'Movies',
        ),
      );

  setUp(() async {
    db = IndexDatabase.memory();
    index = LibraryIndex(openDatabase: Future.value(db), requestGap: Duration.zero);
    await add('1', 'Vault Night', 'Crime', summary: 'A heist goes wrong.');
    await add('2', 'Quiet Streets', 'Crime', summary: 'A detective story.');
    await add('3', 'Seen Before', 'Crime', summary: 'Another heist.', views: 1);
    await add('4', 'Space Rocks', 'Science Fiction', summary: 'A heist in orbit.');
  });
  tearDown(() => db.close());

  Future<List<String>> titles(Map<String, Object?> search) async => [
    for (final t in await AiSuggestions.fill(index, null, search)) t.title,
  ];

  test('genres alone: unwatched titles in them', () async {
    expect(
      await titles({
        'genres_all': ['Crime'],
      }),
      unorderedEquals(['Vault Night', 'Quiet Streets']),
    );
  });

  test('a theme narrows the genres; alone it searches everything', () async {
    expect(
      await titles({
        'genres_all': ['Crime'],
        'text': 'heist',
      }),
      ['Vault Night'],
    );
    expect(await titles({'text': 'heist'}), unorderedEquals(['Vault Night', 'Space Rocks']));
  });

  test('genres to keep out apply to a theme search too', () async {
    expect(
      await titles({
        'text': 'heist',
        'genres_none': ['science fiction'],
      }),
      ['Vault Night'],
    );
  });

  test('animated titles stay out unless the list is for them', () async {
    await add('5', 'Robot Racers', 'Animation', summary: 'A heist on wheels.');
    expect(await titles({'text': 'heist'}), unorderedEquals(['Vault Night', 'Space Rocks']));
    expect(await titles({'text': 'heist', 'animation': 'only'}), ['Robot Racers']);
    expect(
      await titles({'text': 'heist', 'animation': 'allowed'}),
      unorderedEquals(['Vault Night', 'Space Rocks', 'Robot Racers']),
    );
  });
}
