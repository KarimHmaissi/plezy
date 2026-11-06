import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/title_copies.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/title_copy_lookup.dart';
import 'package:plezy/utils/external_ids.dart';
import 'package:plezy/utils/media_server_http_client.dart';

LibraryLookupResult _result(
  List<MediaItem> items, {
  Set<String> succeeded = const {'main', 'xtra'},
  Set<String> failed = const {},
  Set<String> cancelled = const {},
  Set<String> unqueried = const {},
}) => (
  items: items,
  succeededServerIds: succeeded,
  cancelledServerIds: cancelled,
  failedServerIds: failed,
  unqueriedServerIds: unqueried,
);

/// Records every query and answers with [reply].
class _FakeFinder {
  _FakeFinder(this.reply);

  final LibraryLookupResult reply;
  final queries = <TitleQuery>[];
  final aborts = <AbortController?>[];

  Future<LibraryLookupResult> call(TitleQuery query, {AbortController? abort}) async {
    queries.add(query);
    aborts.add(abort);
    return reply;
  }
}

void main() {
  final mainCopy = MediaItem.plex(id: '101', kind: MediaKind.movie, title: 'Sinners', year: 2025, serverId: 'main');
  final xtraCopy = MediaItem.plex(id: '9001', kind: MediaKind.movie, title: 'Sinners', year: 2025, serverId: 'xtra');

  test('a movie by its ids is one lookup and returns the copies across servers', () async {
    final finder = _FakeFinder(_result([mainCopy, xtraCopy]));
    final abort = AbortController();

    final result = await TitleCopies(finder.call).movie(
      title: 'Sinners',
      year: 2025,
      ids: const ExternalIds(tmdb: 1233413, imdb: 'tt31193180'),
      abort: abort,
    );

    expect(finder.queries, hasLength(1));
    final query = finder.queries.single;
    expect(query.kind, MediaKind.movie);
    expect(query.title, 'Sinners');
    expect(query.year, 2025);
    expect(query.ids.tmdb, 1233413);
    expect(finder.aborts.single, same(abort));
    expect([for (final item in result.items) item.serverId], ['main', 'xtra']);
    expect(result.isComplete, isTrue);
  });

  test('an episode goes by its show and numbers', () async {
    final finder = _FakeFinder(_result(const []));

    await TitleCopies(finder.call).episode(
      showTitle: 'The Expanse',
      showYear: 2015,
      showIds: const ExternalIds(tvdb: 280619),
      season: 3,
      episode: 7,
    );

    final query = finder.queries.single;
    expect(query.kind, MediaKind.episode);
    expect(query.showTitle, 'The Expanse');
    expect(query.showYear, 2015);
    expect(query.showIds.tvdb, 280619);
    expect(query.season, 3);
    expect(query.episode, 7);
  });

  group('forItem', () {
    test('a library movie goes by its Plex guid, title and year', () async {
      final finder = _FakeFinder(_result([mainCopy]));
      final item = MediaItem.plex(
        id: '101',
        kind: MediaKind.movie,
        guid: 'plex://movie/5d776d1847dd6e001f6f00a1',
        title: 'Sinners',
        year: 2025,
        serverId: 'main',
      );

      final result = await TitleCopies(finder.call).forItem(item);

      final query = finder.queries.single;
      expect(query.plexGuid, 'plex://movie/5d776d1847dd6e001f6f00a1');
      expect(query.title, 'Sinners');
      expect(query.year, 2025);
      expect(result!.items.single, same(mainCopy));
    });

    test('a non-Plex guid is not passed as a Plex guid', () {
      final item = MediaItem.plex(id: '1', kind: MediaKind.movie, guid: 'com.plexapp.agents.imdb://tt1', title: 'X');

      expect(TitleCopies.queryFor(item)!.plexGuid, isNull);
    });

    test('a library episode goes by its show title and numbers', () {
      final item = MediaItem.plex(
        id: '55',
        kind: MediaKind.episode,
        title: 'Assured Destruction',
        grandparentTitle: 'The Expanse',
        parentIndex: 3,
        index: 7,
      );

      final query = TitleCopies.queryFor(item, showIds: const ExternalIds(tvdb: 280619))!;

      expect(query.kind, MediaKind.episode);
      expect(query.showTitle, 'The Expanse');
      expect(query.showIds.tvdb, 280619);
      expect(query.season, 3);
      expect(query.episode, 7);
    });

    test('asks nothing for an episode without numbers or a show', () {
      final finder = _FakeFinder(_result(const []));
      final copies = TitleCopies(finder.call);

      expect(copies.forItem(MediaItem.plex(id: '1', kind: MediaKind.episode, grandparentTitle: 'X', index: 2)), isNull);
      expect(copies.forItem(MediaItem.plex(id: '2', kind: MediaKind.show, title: 'The Expanse')), isNull);
      expect(finder.queries, isEmpty);
    });
  });

  test('a lookup with a failed, cancelled or offline server is not complete', () {
    expect(_result(const [], failed: {'xtra'}).isComplete, isFalse);
    expect(_result(const [], cancelled: {'xtra'}).isComplete, isFalse);
    expect(_result(const [], unqueried: {'xtra'}).isComplete, isFalse);
    expect(_result(const []).isComplete, isTrue);
  });
}
