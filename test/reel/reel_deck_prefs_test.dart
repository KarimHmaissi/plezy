import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/reel_deck_prefs.dart';

void main() {
  const decks = ['for-you', 'anime-openings', 'most-watched', 'ai:1', 'ai:2'];
  String id(String s) => s;

  test('with nothing arranged the decks keep the app order and For You starts', () {
    const p = ReelDeckPrefs.none;
    expect(p.arrange(decks, id), decks);
    expect(p.shown(decks, id), decks);
    expect(p.start, ReelStartDeck.forYou);
  });

  test('arranged decks come first in their order, new decks after them in the app order', () {
    const p = ReelDeckPrefs(order: ['ai:2', 'anime-openings']);
    expect(p.arrange(decks, id), ['ai:2', 'anime-openings', 'for-you', 'most-watched', 'ai:1']);
  });

  test('hidden decks leave the shown list, except the one playing', () {
    const p = ReelDeckPrefs(hidden: {'most-watched', 'ai:1'});
    expect(p.shown(decks, id), ['for-you', 'anime-openings', 'ai:2']);
    expect(p.shown(decks, id, keep: 'ai:1'), ['for-you', 'anime-openings', 'ai:1', 'ai:2']);
  });

  test('every deck hidden (synced from a device with other decks) shows them all', () {
    const p = ReelDeckPrefs(hidden: {'for-you', 'anime-openings'});
    expect(p.shown(['for-you', 'anime-openings'], id), ['for-you', 'anime-openings']);
  });

  test('the last shown deck cannot be hidden', () {
    const p = ReelDeckPrefs(hidden: {'anime-openings'});
    expect(p.canHide(['for-you', 'anime-openings'], 'for-you'), isFalse);
    expect(p.canHide(['for-you', 'anime-openings', 'ai:1'], 'for-you'), isTrue);
  });

  group('moving', () {
    test('up, down and pinned to the top', () {
      const p = ReelDeckPrefs.none;
      expect(p.moved(known: decks, id: 'ai:1', by: -1).order, [
        'for-you',
        'anime-openings',
        'ai:1',
        'most-watched',
        'ai:2',
      ]);
      expect(p.moved(known: decks, id: 'for-you', by: 1).order, [
        'anime-openings',
        'for-you',
        'most-watched',
        'ai:1',
        'ai:2',
      ]);
      expect(p.moved(known: decks, id: 'ai:2', by: -99).order.first, 'ai:2');
    });

    test('at an end nothing changes', () {
      const p = ReelDeckPrefs.none;
      expect(identical(p.moved(known: decks, id: 'for-you', by: -1), p), isTrue);
      expect(identical(p.moved(known: decks, id: 'ai:2', by: 1), p), isTrue);
      expect(identical(p.moved(known: decks, id: 'nope', by: 1), p), isTrue);
    });

    test('in a picker it moves past the shown neighbour; hidden decks keep their places', () {
      const p = ReelDeckPrefs(hidden: {'anime-openings'});
      final shown = p.shown(decks, id);
      final next = p.moved(known: decks, among: shown, id: 'most-watched', by: -1);
      expect(next.order, ['most-watched', 'for-you', 'anime-openings', 'ai:1', 'ai:2']);
      expect(next.shown(decks, id), ['most-watched', 'for-you', 'ai:1', 'ai:2']);
    });

    test('ids of decks on the other device only are kept after the arranged ones', () {
      const p = ReelDeckPrefs(order: ['ai:9', 'anime-openings']);
      final next = p.moved(known: decks, id: 'ai:2', by: -99);
      expect(next.order.first, 'ai:2');
      expect(next.order.last, 'ai:9');
    });
  });

  test('hide and show again keep the order and start deck', () {
    const p = ReelDeckPrefs(order: ['ai:1'], start: ReelStartDeck.last);
    final hidden = p.withHidden('most-watched', hide: true);
    expect(hidden.hidden, {'most-watched'});
    expect(hidden.order, ['ai:1']);
    expect(hidden.start, ReelStartDeck.last);
    expect(hidden.withHidden('most-watched', hide: false), p);
  });

  test('round-trips through its synced values; unreadable values are today\'s behaviour', () {
    const p = ReelDeckPrefs(order: ['ai:1', 'for-you'], hidden: {'most-watched'}, start: ReelStartDeck.last);
    expect(ReelDeckPrefs.decode(p.encodeDecks(), p.start.name), p);
    expect(ReelDeckPrefs.decode('not json', 'sideways'), ReelDeckPrefs.none);
    expect(ReelDeckPrefs.decode(null, null), ReelDeckPrefs.none);
    expect(ReelDeckPrefs.decode('{"order": [1, "ai:1"], "hidden": "x"}', null).order, ['ai:1']);
  });
}
