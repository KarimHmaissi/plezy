import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/catalog_sources_provider.dart';
import 'package:plezy/services/catalog/home_pins.dart';
import 'package:plezy/services/catalog/home_rows.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/reel_decks.dart' show WhatsNextDeck;
import 'package:plezy/services/reel/reel_home_row.dart';
import 'package:plezy/services/reel/reel_store.dart';

/// A server that has some titles and fails on others.
class _Server implements MediaServerClient {
  _Server(this.server, {this.failing = const {}});

  final String server;
  final Set<String> failing;
  final asked = <String>[];

  /// Reads under way, and the most there were at once.
  int _reading = 0;
  int mostAtOnce = 0;

  @override
  Future<MediaItem?> fetchItem(String id) async {
    asked.add(id);
    _reading++;
    if (_reading > mostAtOnce) mostAtOnce = _reading;
    try {
      await Future<void>.delayed(Duration.zero);
      if (failing.contains(id)) throw Exception('server error');
      return MediaItem(id: id, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Title $id', serverId: server);
    } finally {
      _reading--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A server whose titles read as shows, failing on [failing].
class _ShowServer implements MediaServerClient {
  _ShowServer(this.server, this.make, {this.failing = const {}});

  final String server;
  final MediaItem Function(String id) make;
  final Set<String> failing;
  final asked = <String>[];

  @override
  Future<MediaItem?> fetchItem(String id) async {
    asked.add(id);
    if (failing.contains(id)) throw Exception('server error');
    return make(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// V2-62: Home's "From the Reel" row shows every Save, newest first,
/// read from the copy that was saved; a title that can't be read is left
/// out instead of taking the row down.
void main() {
  late ForkDatabase db;
  late CatalogSourcesProvider sources;
  final now = DateTime.now().toUtc();

  setUp(() {
    db = ForkDatabase.memory();
    Customisation.debugSetLocalDatabase(db);
    Customisation.debugSetStore(LocalCustomisationStore(db));
    sources = CatalogSourcesProvider();
    HomeRowResolver.forgetReelPicks();
  });

  tearDown(() async {
    sources.dispose();
    Customisation.debugSetStore(null);
    Customisation.debugSetLocalDatabase(null);
    await db.close();
  });

  Future<void> save(String id, String serverId, String title, Duration ago) => ReelStore.instance.savePick(
    ReelPick(titleId: 't$id', groupKey: 'g$id', serverId: serverId, ratingKey: id, title: title, at: now.subtract(ago)),
  );

  const row = (id: HomeRowIds.reelPicks, title: 'From the Reel', sources: <String>[]);

  test('every Save, newest first: no cap of ${ReelPick.maxShown} and no 3-day expiry', () async {
    final a = _Server('s1');
    await save('1', 's1', 'Copper Hill', const Duration(hours: 5));
    await save('2', 's1', 'Harbor Lights', const Duration(minutes: 1));
    await save('3', 's1', 'Lantern Bay', const Duration(hours: 1));
    await save('4', 's1', 'Salt Road', const Duration(hours: 9));
    await save('5', 's1', 'Quiet Orchard', const Duration(days: 4));
    await save('6', 's1', 'Amber Field', const Duration(days: 60));

    final hub = await HomeRowResolver(sources: sources, clientFor: (id) => id == 's1' ? a : null).fetch(row);

    expect(hub?.id, 'home:${HomeRowIds.reelPicks}');
    expect(hub?.items.map((i) => i.id), ['2', '3', '1', '4', '5', '6']);
  });

  test('a long list is read a few at a time, and keeps its order', () async {
    final a = _Server('s1');
    for (var i = 1; i <= 25; i++) {
      await save('$i', 's1', 'Title $i', Duration(minutes: i));
    }

    final hub = await HomeRowResolver(sources: sources, clientFor: (id) => id == 's1' ? a : null).fetch(row);

    expect(hub?.items.map((i) => i.id), [for (var i = 1; i <= 25; i++) '$i']);
    expect(a.mostAtOnce, HomeRowResolver.pickFetchesAtOnce);
  });

  test('a reload reads only the Saves it has not read: a new Save is one read, a removal none', () async {
    final a = _Server('s1');
    for (var i = 1; i <= 12; i++) {
      await save('$i', 's1', 'Title $i', Duration(minutes: i + 1));
    }
    HomeRowResolver resolver() => HomeRowResolver(sources: sources, clientFor: (id) => id == 's1' ? a : null);

    await resolver().fetch(row);
    expect(a.asked, hasLength(12));

    a.asked.clear();
    await save('13', 's1', 'Title 13', Duration.zero);
    final hub = await resolver().fetch(row);
    expect(a.asked, ['13'], reason: 'the other Saves were read already');
    expect(hub?.items.map((i) => i.id), ['13', for (var i = 1; i <= 12; i++) '$i']);

    a.asked.clear();
    await ReelStore.instance.removePick('t5');
    final after = await resolver().fetch(row);
    expect(a.asked, isEmpty);
    expect(after?.items.map((i) => i.id), [
      '13',
      for (var i = 1; i <= 12; i++)
        if (i != 5) '$i',
    ]);

    // Home's full refresh reads them all again (watched state and all).
    HomeRowResolver.forgetReelPicks();
    await resolver().fetch(row);
    expect(a.asked, hasLength(12));
  });

  test('a Save its server could not read is asked about again on the next load', () async {
    final a = _Server('s1', failing: {'2'});
    await save('1', 's1', 'Harbor Lights', const Duration(minutes: 3));
    await save('2', 's1', 'Lantern Bay', const Duration(minutes: 2));
    HomeRowResolver resolver() => HomeRowResolver(sources: sources, clientFor: (id) => id == 's1' ? a : null);

    await resolver().fetch(row);
    a.asked.clear();
    await resolver().fetch(row);
    expect(a.asked, ['2']);
  });

  test('a title its server fails on, or on a server not connected, is left out', () async {
    final a = _Server('s1', failing: {'2'});
    await save('1', 's1', 'Harbor Lights', const Duration(minutes: 3));
    await save('2', 's1', 'Lantern Bay', const Duration(minutes: 2));
    await save('3', 's2', 'Quiet Orchard', const Duration(minutes: 1));

    final hub = await HomeRowResolver(sources: sources, clientFor: (id) => id == 's1' ? a : null).fetch(row);

    expect(hub?.items.map((i) => i.id), ['1']);
    expect(a.asked, ['2', '1']);
  });

  group("D22: the What's next after card", () {
    /// A show server: the finished show reads as a show.
    MediaItem show(String id) => MediaItem(
      id: id,
      backend: MediaBackend.plex,
      kind: MediaKind.show,
      title: 'Harbor Lights',
      thumbPath: '/thumb/$id',
      artPath: '/art/$id',
      serverId: 's1',
    );

    test('leads the row, opens the deck, and the finished show is never repeated as a Save', () async {
      final a = _ShowServer('s1', show);
      await save('1', 's1', 'Lantern Bay', const Duration(minutes: 3));
      await save('9', 's1', 'Harbor Lights', const Duration(minutes: 2));

      final hub = await HomeRowResolver(
        sources: sources,
        clientFor: (id) => id == 's1' ? a : null,
        whatsNext: () async => (serverId: 's1', ratingKey: '9'),
      ).fetch(row);

      expect(hub?.items.map((i) => i.id), ['9', '1']);
      final card = hub!.items.first;
      expect(ReelHomeRow.entryDeck(card), WhatsNextDeck.deckId);
      expect(card.title, "What's next after Harbor Lights");
      expect(card.summary, "You finished Harbor Lights. Sample what's next in the Reel.");
      expect(card.thumbPath, '/thumb/9');
      expect(card.artPath, '/art/9');
      expect(card.kind, MediaKind.show);
      expect(ReelHomeRow.entryDeck(hub.items.last), isNull, reason: 'a Save opens as ever');
    });

    test('no finished show, its server not connected, or its read failing: no card, the Saves still show', () async {
      await save('1', 's1', 'Lantern Bay', const Duration(minutes: 3));
      final a = _ShowServer('s1', show, failing: {'9'});

      Future<List<String>?> ids(Future<({String serverId, String ratingKey})?> Function() whatsNext) async =>
          (await HomeRowResolver(
            sources: sources,
            clientFor: (id) => id == 's1' ? a : null,
            whatsNext: whatsNext,
          ).fetch(row))?.items.map((i) => i.id).toList();

      expect(await ids(() async => null), ['1']);
      expect(await ids(() async => (serverId: 's2', ratingKey: '9')), ['1']);
      expect(await ids(() async => (serverId: 's1', ratingKey: '9')), ['1']);
      expect(await ids(() async => throw StateError('brain closed')), ['1']);
    });

    test('a card with no Saves is the whole row', () async {
      final a = _ShowServer('s1', show);
      final hub = await HomeRowResolver(
        sources: sources,
        clientFor: (_) => a,
        whatsNext: () async => (serverId: 's1', ratingKey: '9'),
      ).fetch(row);
      expect(hub?.items.map((i) => i.id), ['9']);
      expect(a.asked, ['9']);
    });
  });

  test('no Saves: an empty row, no server read', () async {
    final a = _Server('s1');
    final hub = await HomeRowResolver(sources: sources, clientFor: (_) => a).fetch(row);
    expect(hub?.items, isEmpty);
    expect(a.asked, isEmpty);
  });
}
