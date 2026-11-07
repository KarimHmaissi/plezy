import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/copy_fallback.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_version.dart';

import '../test_helpers/media_items.dart';

void main() {
  MediaVersion version(String id, int height, int bitrate, {bool missing = false}) => MediaVersion(
    id: id,
    height: height,
    bitrate: bitrate,
    parts: [MediaPart(id: 'p$id', exists: missing ? false : null)],
  );

  // One film on two servers, a 4K and a 1080p version of it on each (the
  // shape behind the 6 Nov report), as invented servers.
  final onA = testMediaItem(
    id: '101',
    title: 'Harbor Lights',
    serverId: 'server-a',
    serverName: 'Server A',
    mediaVersions: [version('a1080', 1080, 9000), version('a4k', 2160, 60000)],
  );
  final onB = testMediaItem(
    id: '202',
    title: 'Harbor Lights',
    serverId: 'server-b',
    serverName: 'Server B',
    mediaVersions: [version('b4k', 2160, 58000), version('b1080', 1080, 8500)],
  );

  String key(CopySource s) => s.key;

  test('after the 4K went missing and the 1080p got 503s on one server, the other server goes next, 4K first', () {
    final tried = {copySourceKey(onA, onA.mediaVersions![1]), copySourceKey(onA, onA.mediaVersions![0])};
    final order = orderCopyFallbacks(
      copies: [onA, onB],
      referenceHeight: 2160,
      tried: tried,
      failedServerIds: {'server-a'},
    );
    expect(order.map(key), ['server-b|202|b4k', 'server-b|202|b1080']);
  });

  test('the same quality on a fresh server beats the same quality on the failing one', () {
    final otherLibraryOnA = testMediaItem(
      id: '303',
      serverId: 'server-a',
      libraryTitle: 'Movies 4K',
      mediaVersions: [version('a4k-2', 2160, 70000)],
    );
    final order = orderCopyFallbacks(
      copies: [onA, otherLibraryOnA, onB],
      referenceHeight: 2160,
      tried: {copySourceKey(onA, onA.mediaVersions![1])},
      failedServerIds: {'server-a'},
    );
    // Server B's 4K, though its bitrate is lower, then Server A's other 4K
    // library, then the 1080p copies (fresh server first).
    expect(order.map(key).take(4), [
      'server-b|202|b4k',
      'server-a|303|a4k-2',
      'server-b|202|b1080',
      'server-a|101|a1080',
    ]);
  });

  test('lower qualities go tallest first, and taller ones come last', () {
    final sd = testMediaItem(id: '404', serverId: 'server-c', mediaVersions: [version('c480', 480, 2000)]);
    final order = orderCopyFallbacks(copies: [sd, onA, onB], referenceHeight: 1080, tried: const {});
    expect(order.map((s) => s.height), [1080, 1080, 480, 2160, 2160]);
  });

  test('versions the server flagged missing are never tried', () {
    final flagged = onA.copyWith(
      mediaVersions: [version('a1080', 1080, 9000), version('a4k', 2160, 60000, missing: true)],
    );
    final order = orderCopyFallbacks(copies: [flagged], referenceHeight: 2160);
    expect(order.map(key), ['server-a|101|a1080']);
  });

  test('a file that failed recently goes last rather than being dropped', () {
    final order = orderCopyFallbacks(
      copies: [onB],
      referenceHeight: 2160,
      isRemembered: (s) => s.key == 'server-b|202|b4k',
    );
    expect(order.map(key), ['server-b|202|b1080', 'server-b|202|b4k']);
  });

  test('a copy listed without versions counts as tried once any of its versions was', () {
    final bare = testMediaItem(id: '202', serverId: 'server-b');
    expect(copySourceWasTried(CopySource(bare, 0), {'server-b|202|b4k'}), isTrue);
    expect(copySourceWasTried(CopySource(onB, 1), {'server-b|202|'}), isTrue);
    expect(copySourceWasTried(CopySource(onB, 1), {'server-a|202|b1080'}), isFalse);
  });

  test('a copy listed twice keeps its first entry, so checked versions win', () {
    final checked = onA.copyWith(
      mediaVersions: [version('a1080', 1080, 9000), version('a4k', 2160, 60000, missing: true)],
    );
    final order = orderCopyFallbacks(copies: [checked, onA], referenceHeight: 2160);
    expect(order.map(key), ['server-a|101|a1080']);
  });

  test('the log line numbers servers and never names them', () {
    final servers = <String?>[];
    int index(String? id) {
      if (!servers.contains(id)) servers.add(id);
      return servers.indexOf(id);
    }

    final line = copyFallbackLogLine(
      reason: CopyFallbackReason.http503,
      attempt: 2,
      from: CopySource(onA, 0),
      to: CopySource(onB, 0),
      serverIndex: index,
    );
    expect(line, '[CopyFallback] attempt 2/3 reason=http503 from=1080p@s0 to=4K@s1');
    expect(line, isNot(contains('Server')));
    expect(line, isNot(contains('server-')));
    expect(line, isNot(contains('Harbor')));

    final sameItem = copyFallbackLogLine(
      reason: CopyFallbackReason.missing,
      attempt: 1,
      from: CopySource(onA, 1),
      to: CopySource(onA, 0),
      serverIndex: index,
    );
    expect(sameItem, endsWith('from=4K@s0 to=1080p@s0 (same item, other version)'));
  });

  test('quality labels', () {
    expect(copySourceQualityLabel(CopySource(onA, 1)), '4K');
    expect(copySourceQualityLabel(CopySource(onA, 0)), '1080p');
    expect(copySourceQualityLabel(CopySource(testMediaItem(id: 'x'), 0)), isNull);
  });
}
