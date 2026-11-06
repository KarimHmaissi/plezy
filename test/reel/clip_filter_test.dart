import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/reel_playback_profile.dart';

PlexExtraClip _x(String title, {int i = 0, String subtype = 'trailer'}) => PlexExtraClip(
  ratingKey: 'k$i',
  title: title,
  partKey: '/services/iva/assets/$i/video.mp4',
  subtype: subtype,
  index: i,
);

void main() {
  group('films', () {
    test('a teaser beats the trailers', () {
      final pick = ClipFilter.filmTrailer([_x('Official Trailer', i: 0), _x('Teaser', i: 1)]);
      expect(pick?.title, 'Teaser');
    });

    test('the earliest plain trailer, not the final or international cut', () {
      final pick = ClipFilter.filmTrailer([
        _x('Final Trailer', i: 0),
        _x('International Trailer', i: 1),
        _x('Official Trailer', i: 2),
        _x('Trailer 2', i: 3),
      ]);
      expect(pick?.title, 'Official Trailer');
    });

    test('alternate-format (BASL) and 4K cuts, scenes and featurettes are never picked', () {
      final pick = ClipFilter.filmTrailer([
        _x('Official Trailer (BASL)', i: 0),
        _x('4K Trailer', i: 1),
        _x('Opening Scene', i: 2, subtype: 'sceneOrSample'),
        _x('Behind the Scenes', i: 3, subtype: 'behindTheScenes'),
        _x('Deleted Scene', i: 4, subtype: 'deletedScene'),
      ]);
      expect(pick, isNull);
    });

    test('only trailers count', () {
      expect(ClipFilter.filmTrailer([_x('Making Of', subtype: 'featurette')]), isNull);
    });
  });

  group('shows', () {
    test('a final-season trailer is dropped; the season 1 trailer is kept', () {
      final pick = ClipFilter.showTrailer([
        _x('Season 2 Official Trailer', i: 0),
        _x('Final Season Trailer', i: 1),
        _x('Season 1 Trailer', i: 2),
      ], showTitle: 'The Show');
      expect(pick?.title, 'Season 1 Trailer');
    });

    test('the plain show name and a teaser pass; date announcements and recaps do not', () {
      expect(ClipFilter.showTrailer([_x('The Show', i: 0)], showTitle: 'The Show')?.title, 'The Show');
      expect(
        ClipFilter.showTrailer([_x('Official Trailer', i: 0), _x('Teaser', i: 1)], showTitle: 'The Show')?.title,
        'Teaser',
      );
      expect(ClipFilter.showTrailer([_x('Date Announcement')], showTitle: 'The Show'), isNull);
      expect(ClipFilter.showTrailer([_x('Season 1 Recap')], showTitle: 'The Show'), isNull);
      expect(ClipFilter.showTrailer([_x('Uncovering The Show')], showTitle: 'The Show'), isNull);
    });

    test('later seasons in any spelling are dropped', () {
      for (final t in [
        'Season Two Trailer',
        'S3 Teaser',
        'Part 2 Trailer',
        'Second Season Trailer',
        'Volume II Trailer',
      ]) {
        expect(ClipFilter.showTrailer([_x(t)], showTitle: 'The Show'), isNull, reason: t);
      }
    });

    test('a show-named trailer with a suffix still passes', () {
      expect(ClipFilter.showTrailer([_x('The Show: Official Trailer')], showTitle: 'The Show')?.title, isNotNull);
    });
  });

  group('extras response rows', () {
    test('reads the part key and skips rows with no part', () {
      final row = PlexExtraClip.fromJson({
        'ratingKey': 52601,
        'title': 'Official Trailer',
        'subtype': 'trailer',
        'extraType': 1,
        'duration': 142000,
        'Media': [
          {
            'container': 'mp4',
            'Part': [
              {'key': '/services/iva/assets/1/video.mp4?fmt=4&bitrate=5000'},
            ],
          },
        ],
      }, 3);
      expect(row?.ratingKey, '52601');
      expect(row?.partKey, startsWith('/services/iva/assets/'));
      expect(row?.durationMs, 142000);
      expect(row?.isTrailer, isTrue);
      expect(row?.index, 3);
      expect(PlexExtraClip.fromJson({'ratingKey': 1, 'title': 'x'}, 0), isNull);
    });
  });

  group('anime openings', () {
    Map<String, dynamic> video(String name, {bool nc = true, int res = 1080, int size = 30}) => {
      'id': name.hashCode,
      'link': 'https://v.animethemes.moe/$name.webm',
      'nc': nc,
      'resolution': res,
      'size': size,
    };

    Map<String, dynamic> theme(String type, int? seq, List<Map<String, dynamic>> entries) => {
      'type': type,
      'sequence': seq,
      'song': {'title': 'song $type$seq'},
      'animethemeentries': entries,
    };

    test('OP1 of episode 1, creditless 1080p preferred', () {
      final op = ClipFilter.firstOpening({
        'animethemes': [
          theme('ED', 1, [
            {
              'episodes': '1-12',
              'videos': [video('ED1')],
            },
          ]),
          theme('OP', 2, [
            {
              'episodes': '13-24',
              'videos': [video('OP2')],
            },
          ]),
          theme('OP', 1, [
            {
              'episodes': '1-12',
              'spoiler': false,
              'nsfw': false,
              'videos': [video('OP1-lyrics', nc: false), video('OP1-720', res: 720), video('OP1')],
            },
          ]),
        ],
      });
      expect(op?.url, 'https://v.animethemes.moe/OP1.webm');
      expect(op?.creditless, isTrue);
      expect(op?.song, 'song OP1');
    });

    test('every file of OP1 is a candidate; the profile picks the height (V2-16)', () {
      final anime = {
        'animethemes': [
          theme('OP', 1, [
            {
              'episodes': '1-12',
              'videos': [video('OP1-480', res: 480, size: 5), video('OP1-720', res: 720, size: 20), video('OP1')],
            },
          ]),
        ],
      };
      expect(ClipFilter.openings(anime).map((o) => o.height), [480, 720, 1080]);
      const cover = ReelPlaybackProfile(screen: ReelScreen.compactPortrait, maxHeight: 720);
      expect(ClipFilter.firstOpening(anime, profile: cover)?.url, endsWith('OP1-720.webm'));
      expect(ClipFilter.firstOpening(anime)?.url, endsWith('/OP1.webm'));
    });

    test('spoiler or NSFW entries and openings that start later are refused', () {
      expect(
        ClipFilter.firstOpening({
          'animethemes': [
            theme('OP', 1, [
              {
                'episodes': '1-12',
                'spoiler': true,
                'videos': [video('a')],
              },
              {
                'episodes': '2-12',
                'videos': [video('b')],
              },
              {
                'episodes': '1',
                'nsfw': true,
                'videos': [video('c')],
              },
            ]),
          ],
        }),
        isNull,
      );
    });

    test('a sole OP with no sequence counts as OP1; never an ED alone', () {
      expect(
        ClipFilter.firstOpening({
          'animethemes': [
            theme('OP', null, [
              {
                'episodes': null,
                'videos': [video('solo')],
              },
            ]),
          ],
        })?.url,
        endsWith('solo.webm'),
      );
      expect(
        ClipFilter.firstOpening({
          'animethemes': [
            theme('ED', 1, [
              {
                'episodes': '1-12',
                'videos': [video('ed')],
              },
            ]),
          ],
        }),
        isNull,
      );
    });
  });
}
