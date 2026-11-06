import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';

ReelCardData _card(String id, {double? imdb, double? tmdb, double? audience}) => ReelCardData(
  title: ReelTitle(
    titleId: id,
    groupKey: 'g$id',
    title: 'Title $id',
    isShow: false,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: id, groupKey: 'g$id'),
    seen: SeenState.unseen,
    imdb: imdb,
    tmdb: tmdb,
    audience: audience,
  ),
  best: IndexedTitle(
    id: 's1:$id',
    serverId: 's1',
    serverName: 'S',
    libraryKey: '1',
    libraryTitle: 'Films',
    ratingKey: id,
    type: 'movie',
    title: 'Title $id',
    genres: '',
    countries: '',
    directors: '',
    writers: '',
    cast: '',
    collections: '',
    groupKey: 'g$id',
    summary: '',
  ),
);

void main() {
  test('code order keeps to well-rated titles, in its own order, unrated last', () {
    final kept = ForYouDeck.worthShowing([
      _card('unrated'),
      _card('bad', imdb: 2.4),
      _card('good', imdb: 7.8),
      _card('meh', imdb: 5.9),
      _card('tmdbOnly', tmdb: 6.6),
      _card('plexOnly', audience: 3.1),
      _card('fine', imdb: 6.0),
    ]);
    expect(kept.map((c) => c.id), ['good', 'tmdbOnly', 'fine', 'unrated']);
  });

  test('IMDb outranks the other scores when both are known', () {
    final kept = ForYouDeck.worthShowing([_card('a', imdb: 3.4, tmdb: 7.0)]);
    expect(kept, isEmpty);
  });
}
