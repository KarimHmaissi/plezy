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
    Map<String, dynamic> video(
      String name, {
      bool nc = true,
      int res = 1080,
      int size = 30,
      Object? overlap = 'NONE',
      bool lyrics = false,
      bool subbed = false,
      String? source,
    }) => {
      'id': name.hashCode,
      'link': 'https://v.animethemes.moe/$name.webm',
      'nc': nc,
      'resolution': res,
      'size': size,
      'overlap': overlap,
      'lyrics': lyrics,
      'subbed': subbed,
      'source': source,
    };

    const captionsOn = ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 1080, captions: true);

    Map<String, dynamic> theme(String type, int? seq, List<Map<String, dynamic>> entries) => {
      'type': type,
      'sequence': seq,
      'song': {'title': 'song $type$seq'},
      'animethemeentries': entries,
    };

    Map<String, dynamic> op1(List<Map<String, dynamic>> videos) => {
      'animethemes': [
        theme('OP', 1, [
          {'episodes': '1-12', 'videos': videos},
        ]),
      ],
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

    group('episode footage, captions and source (V2-17)', () {
      test('an opening with the episode over it is never a candidate, nor an unknown overlap', () {
        final anime = op1([
          video('over', overlap: 'OVER'),
          video('missing', overlap: null),
          video('numeric', overlap: 2),
          video('new', overlap: 'SOMETIMES'),
        ]);
        expect(ClipFilter.openings(anime), isEmpty);
        expect(ClipFilter.firstOpening(anime), isNull);
      });

      test('a transition plays only when no file without episode footage is left', () {
        expect(
          ClipFilter.firstOpening(
            op1([
              video('trans-1080', overlap: 'TRANS', source: 'BD'),
              video('clean-480', res: 480, nc: false, lyrics: true, source: 'VHS'),
            ]),
          )?.url,
          endsWith('clean-480.webm'),
        );
        final fallback = ClipFilter.firstOpening(
          op1([video('trans', overlap: 'TRANS'), video('over', overlap: 'OVER')]),
        );
        expect(fallback?.url, endsWith('/trans.webm'));
        expect(fallback?.transition, isTrue);
      });

      test('creditless first, then no lyrics or subtitles, then BD, WEB, others', () {
        expect(
          ClipFilter.firstOpening(op1([video('credited', nc: false), video('creditless-subbed', subbed: true)]))?.url,
          endsWith('creditless-subbed.webm'),
        );
        expect(
          ClipFilter.firstOpening(
            op1([video('lyrics-bd', lyrics: true, source: 'BD'), video('clean-web', source: 'WEB')]),
          )?.url,
          endsWith('clean-web.webm'),
        );
        expect(
          ClipFilter.firstOpening(
            op1([video('raw', source: 'RAW'), video('none'), video('web', source: 'WEB'), video('bd', source: 'BD')]),
          )?.url,
          endsWith('/bd.webm'),
        );
        expect(
          ClipFilter.firstOpening(op1([video('dvd', source: 'DVD'), video('web', source: 'WEB')]))?.url,
          endsWith('/web.webm'),
        );
      });

      test('with captions on, lyrics or subtitles rank first; creditless still comes before them', () {
        final anime = op1([video('clean', source: 'BD'), video('lyrics', lyrics: true, source: 'WEB')]);
        expect(ClipFilter.firstOpening(anime)?.url, endsWith('/clean.webm'));
        expect(ClipFilter.firstOpening(anime, profile: captionsOn)?.url, endsWith('/lyrics.webm'));
        expect(
          ClipFilter.firstOpening(
            op1([video('credited-subbed', nc: false, subbed: true), video('creditless-clean')]),
            profile: captionsOn,
          )?.url,
          endsWith('creditless-clean.webm'),
        );
      });

      test('the rank decides before height; at the profile height the larger file wins', () {
        final anime = op1([
          video('bd-720-small', res: 720, size: 10, source: 'BD'),
          video('bd-720-large', res: 720, size: 50, source: 'BD'),
          video('bd-1080', size: 90, source: 'BD'),
          video('web-480', res: 480, source: 'WEB'),
        ]);
        const cover = ReelPlaybackProfile(screen: ReelScreen.compactPortrait, maxHeight: 720);
        expect(ClipFilter.firstOpening(anime, profile: cover)?.url, endsWith('bd-720-large.webm'));
        expect(ClipFilter.firstOpening(anime)?.url, endsWith('bd-1080.webm'));
      });

      test('the opening keeps what ranks it', () {
        final op = ClipFilter.openings(
          op1([video('a', overlap: 'TRANS', nc: false, subbed: true, source: 'WEB')]),
        ).single;
        expect(op.transition, isTrue);
        expect(op.creditless, isFalse);
        expect(op.captioned, isTrue);
        expect(op.source, 'WEB');
      });
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
