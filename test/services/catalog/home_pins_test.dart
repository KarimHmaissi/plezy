import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/catalog/home_pins.dart';

void main() {
  group('Home layout in the Plezy list description', () {
    test('round-trips pins (in order) and hidden rows compactly', () {
      const layout = (
        pinned: ['chart:boxoffice', 'list:some-user:4521837', 'chart:anticipated:shows'],
        hidden: ['_continue_watching_', 'home.movies.recent'],
      );
      final description = writeHomeLayout(null, layout);
      expect(description, 'Plezy app settings [plezy:home=bo,4521837,as][plezy:hide=cw,home.movies.recent]');

      final parsed = parseHomeLayout(description);
      expect(parsed.pinned, ['chart:boxoffice', 'list:*:4521837', 'chart:anticipated:shows']);
      expect(parsed.hidden, ['_continue_watching_', 'home.movies.recent']);
    });

    test('keeps other description text and replaces only the settings line', () {
      const first = (pinned: ['chart:boxoffice'], hidden: <String>[]);
      final written = writeHomeLayout('My notes\nsecond line', first);
      expect(written, 'My notes\nsecond line\nPlezy app settings [plezy:home=bo]');

      final rewritten = writeHomeLayout(written, (pinned: <String>[], hidden: ['_pick_back_up_continue_']));
      expect(rewritten, 'My notes\nsecond line\nPlezy app settings[plezy:hide=pb]');
      expect(writeHomeLayout(rewritten, emptyHomeLayout), 'My notes\nsecond line');
    });

    test('a list pinned with its owner and one read back from Trakt are the same row', () {
      expect(samePinnedRow('list:donxy:99', 'list:*:99'), isTrue);
      expect(samePinnedRow('list:me:99', 'list:me:100'), isFalse);
      expect(samePinnedRow('chart:boxoffice', 'chart:boxoffice'), isTrue);
    });

    test('missing, empty and repeated entries are tolerated', () {
      expect(parseHomeLayout(null), emptyHomeLayout);
      expect(parseHomeLayout('no marker here').pinned, isEmpty);
      final parsed = parseHomeLayout('[plezy:home=bo,,bo, 12 ][plezy:hide=]');
      expect(parsed.pinned, ['chart:boxoffice', 'list:*:12']);
      expect(parsed.hidden, isEmpty);
    });

    test('characters that would break the marker are dropped from row keys', () {
      final description = writeHomeLayout(null, (pinned: <String>[], hidden: ['odd]key, with;stuff']));
      expect(parseHomeLayout(description).hidden, ['oddkeywithstuff']);
    });

    test('pins cost a few characters each', () {
      final layout = (pinned: [for (var i = 0; i < 100; i++) 'list:someone:${10000000 + i}'], hidden: <String>[]);
      // 8-digit list ids plus a comma each, plus the fixed wrapper.
      expect(writeHomeLayout(null, layout).length, lessThan(100 * 9 + 40));
    });
  });
}
