import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel_extras_shape.dart';

/// V2-20 step 1: the extras-shape probe counts the shape of the servers'
/// extras, and never lets a title, key, URL or server name into a line.
Map<String, dynamic> _media({
  String? resolution,
  int? bitrate,
  String? video,
  String? profile,
  String? audio,
  int? channels,
  String? container,
  List<String> parts = const [],
}) => {
  'videoResolution': ?resolution,
  'bitrate': ?bitrate,
  'videoCodec': ?video,
  'videoProfile': ?profile,
  'audioCodec': ?audio,
  'audioChannels': ?channels,
  'container': ?container,
  'Part': [
    for (final p in parts) {'key': p, 'file': '/srv/media/Harbor Lights/Harbor Lights Trailer.mkv'},
  ],
};

Map<String, dynamic> _extra(String ratingKey, String title, List<Map<String, dynamic>> media, {String? subtype}) => {
  'ratingKey': ratingKey,
  'title': title,
  'subtype': ?subtype,
  'Media': media,
};

const _ivaKey = '/services/iva/assets/9917/video.mp4?fmt=4&bitrate=5000';

void main() {
  group('ExtrasShape', () {
    test('counts Media per extra, their fields, and the variety step 2 waits on', () {
      final shape = ExtrasShape()
        ..addCopy([
          // An IVA trailer offered at two sizes.
          _extra('801', 'Harbor Lights Trailer', [
            _media(
              resolution: '1080',
              bitrate: 5000,
              video: 'h264',
              profile: 'high',
              audio: 'aac',
              channels: 2,
              container: 'mp4',
              parts: [_ivaKey],
            ),
            _media(
              resolution: '720',
              bitrate: 2000,
              video: 'h264',
              profile: 'high',
              audio: 'aac',
              channels: 2,
              container: 'mp4',
              parts: ['/services/iva/assets/9917/video.mp4?fmt=4&bitrate=2000'],
            ),
          ], subtype: 'trailer'),
          // A local 4K HEVC trailer with DTS.
          _extra('802', 'Harbor Lights Teaser', [
            _media(
              resolution: '4k',
              bitrate: 42000,
              video: 'hevc',
              profile: 'main 10',
              audio: 'dts',
              channels: 6,
              container: 'mkv',
              parts: ['/library/parts/77/1700000000/file.mkv'],
            ),
          ], subtype: 'trailer'),
          // A featurette with no Media at all.
          _extra('803', 'Making Harbor Lights', [], subtype: 'behindTheScenes'),
          'not a row',
        ])
        ..addCopy(const [], is4k: true);

      expect(shape.copies, 2);
      expect(shape.copies4k, 1);
      expect(shape.copiesWithExtras, 1);
      expect(shape.extras, 3);
      expect(shape.trailers, 2);
      expect(shape.mediaPerExtra, {'2': 1, '1': 1, '0': 1});
      expect(shape.partsPerMedia, {'1': 3});
      expect(shape.resolution, {'1080': 1, '720': 1, '4k': 1});
      expect(shape.bitrate, {'5-10M': 1, '1.5-5M': 1, '20M+': 1});
      expect(shape.videoCodec, {'h264': 2, 'hevc': 1});
      expect(shape.videoProfile, {'high': 2, 'main 10': 1});
      expect(shape.audioCodec, {'aac': 2, 'dts': 1});
      expect(shape.channels, {'2': 2, '6': 1});
      expect(shape.container, {'mp4': 2, 'mkv': 1});
      expect(shape.partSource, {'iva': 2, 'library': 1});
      expect(shape.partBitrate, {'5-10M': 1, '1.5-5M': 1, 'none': 1});
      expect(shape.multiMedia, 1);
      expect(shape.differResolution, 1);
      expect(shape.differBitrate, 1);
      expect(shape.differVideoCodec, 0);
      expect(shape.differAudioCodec, 0);

      final lines = shape.lines();
      expect(lines, everyElement(startsWith('[ReelProbe] extras-shape')));
      expect(lines.last, contains('variety: 1 extras with more than one Media'));
      expect(lines.join('\n'), contains('media per extra {0: 1, 1: 1, 2: 1}'));
    });

    test('no title, rating key, part URL or file path reaches a line', () {
      final shape = ExtrasShape()
        ..addCopy([
          _extra('80123', 'Harbor Lights Trailer', [
            _media(
              resolution: '1080',
              bitrate: 5000,
              video: 'h264',
              audio: 'aac',
              channels: 2,
              container: 'mp4',
              parts: [_ivaKey],
            ),
          ], subtype: 'trailer'),
        ]);
      final text = shape.lines().join('\n');
      for (final secret in ['Harbor', '80123', '9917', '/services', '/srv', 'video.mp4', 'fmt=']) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
    });

    test('a server word that is not a codec-like word counts as other', () {
      final shape = ExtrasShape()
        ..addCopy([
          _extra('1', 'Trailer', [
            _media(
              resolution: 'Harbor Lights (Server A)',
              video: 'https://server-a.example/x',
              profile: 'a profile far longer than any codec profile',
              audio: '',
              container: 'MP4',
            ),
          ]),
        ]);
      expect(shape.resolution, {'other': 1});
      expect(shape.videoCodec, {'other': 1});
      expect(shape.videoProfile, {'other': 1});
      expect(shape.audioCodec, {'?': 1});
      expect(shape.container, {'mp4': 1});
      expect(shape.channels, {'?': 1});
      expect(shape.bitrate, {'?': 1});
      expect(shape.partsPerMedia, {'0': 1});
      expect(shape.lines().join('\n'), isNot(contains('Server A')));
    });

    test('part sources and key bitrates', () {
      expect(ExtrasShape.partSourceOf(null), 'none');
      expect(ExtrasShape.partSourceOf(_ivaKey), 'iva');
      expect(ExtrasShape.partSourceOf('/library/parts/5/file.mp4'), 'library');
      expect(ExtrasShape.partSourceOf('https://server-a.example/elsewhere'), 'other');
      expect(ExtrasShape.partBitrateOf(_ivaKey), '5-10M');
      expect(ExtrasShape.partBitrateOf('/library/parts/5/file.mp4'), 'none');
      expect(ExtrasShape.partBitrateOf('/x?bitrate=lots'), 'other');
    });
  });

  group('probeExtrasShape', () {
    ReelTitle title(String id, List<ReelCopy> copies) =>
        ReelTitle(titleId: id, groupKey: id, title: 'Harbor Lights', isShow: false, copies: copies);

    test('reads every copy once, one at a time, and counts failed and skipped reads', () async {
      final asked = <String>[];
      var inFlight = 0;
      final shape = await probeExtrasShape(
        [
          title('t1', const [
            ReelCopy(serverId: 'a', ratingKey: '1'),
            ReelCopy(serverId: 'a', ratingKey: '2', is4k: true),
          ]),
          title('t2', const [ReelCopy(serverId: 'b', ratingKey: '3')]),
          title('t3', const [ReelCopy(serverId: 'a', ratingKey: '4')]),
        ],
        (copy) async {
          expect(inFlight, 0, reason: 'one request at a time');
          inFlight++;
          asked.add(copy.ratingKey);
          await Future<void>.delayed(Duration.zero);
          inFlight--;
          return switch (copy.ratingKey) {
            '2' => throw Exception('timed out'),
            '3' => null,
            _ => [
              _extra('9${copy.ratingKey}', 'Trailer', [
                _media(resolution: '1080', parts: [_ivaKey]),
              ], subtype: 'trailer'),
            ],
          };
        },
        gap: Duration.zero,
      );
      expect(asked, ['1', '2', '3', '4']);
      expect(shape.copies, 2);
      expect(shape.copies4k, 0);
      expect(shape.failed, 1);
      expect(shape.skipped, 1);
      expect(shape.extras, 2);
    });

    test('stops at the title and read caps', () async {
      final titles = [
        for (var i = 0; i < 10; i++)
          title('t$i', [ReelCopy(serverId: 'a', ratingKey: '$i'), ReelCopy(serverId: 'a', ratingKey: '$i-4k')]),
      ];
      var reads = 0;
      Future<List<Object?>?> read(ReelCopy _) async {
        reads++;
        return const [];
      }

      await probeExtrasShape(titles, read, maxTitles: 3, gap: Duration.zero);
      expect(reads, 6);

      reads = 0;
      final shape = await probeExtrasShape(titles, read, maxReads: 5, gap: Duration.zero);
      expect(reads, 5);
      expect(shape.copies, 5);
    });
  });
}
