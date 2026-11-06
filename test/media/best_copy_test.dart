import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item_merge.dart';
import 'package:plezy/media/media_version.dart';

import '../test_helpers/media_items.dart';

void main() {
  MediaVersion version(int? bitrate, int? height) =>
      MediaVersion(id: '$bitrate-$height', bitrate: bitrate, height: height);

  test('best copy is the highest bitrate, skipping unavailable servers', () {
    final low = testMediaItem(id: 'a', serverId: 's1', mediaVersions: [version(8000, 1080)]);
    final high = testMediaItem(id: 'b', serverId: 's2', mediaVersions: [version(60000, 2160)]);
    final offline = testMediaItem(id: 'c', serverId: 's3', mediaVersions: [version(90000, 2160)]);
    expect(bestLibraryCopy([low, high, offline], isAvailable: (c) => c.serverId != 's3'), same(high));
    expect(bestLibraryCopy([low, offline], isAvailable: (c) => c.serverId != 's3'), same(low));
    expect(bestLibraryCopy([offline], isAvailable: (c) => c.serverId != 's3'), isNull);
  });

  test('equal bitrates fall back to resolution', () {
    final hd = testMediaItem(id: 'a', serverId: 's1', mediaVersions: [version(null, 1080)]);
    final uhd = testMediaItem(id: 'b', serverId: 's2', mediaVersions: [version(null, 2160)]);
    expect(bestLibraryCopy([hd, uhd]), same(uhd));
  });

  test('play defaults to the highest-bitrate version', () {
    expect(bestVersionIndex(null), 0);
    expect(bestVersionIndex([version(5000, 1080)]), 0);
    expect(bestVersionIndex([version(5000, 1080), version(40000, 2160), version(12000, 1080)]), 1);
    expect(bestVersionIndex([version(null, 720), version(null, 1080)]), 1);
  });

  // Fork: a broken best copy no longer blocks Play.
  test('a version that failed recently gives way to the next best, unless all did', () {
    final versions = [version(5000, 1080), version(40000, 2160), version(12000, 1080)];
    expect(bestVersionIndex(versions, isBroken: (v) => v.bitrate == 40000), 2);
    expect(bestVersionIndex(versions, isBroken: (v) => v.bitrate != 5000), 0);
    expect(bestVersionIndex(versions, isBroken: (_) => true), 1, reason: 'with nothing left, the usual best');
  });

  test('a copy whose files all failed recently gives way to the next best copy', () {
    final low = testMediaItem(id: 'a', serverId: 's1', mediaVersions: [version(8000, 1080)]);
    final high = testMediaItem(id: 'b', serverId: 's2', mediaVersions: [version(60000, 2160)]);
    expect(bestLibraryCopy([low, high], isBroken: (c) => c.id == 'b'), same(low));
    expect(bestLibraryCopy([low, high], isBroken: (_) => true), same(high));
  });
}
