import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/reel_playback_profile.dart';

PlexExtraClip _x(String title, {int i = 0, String subtype = 'trailer', int? seconds}) => PlexExtraClip(
  ratingKey: 'k$i',
  title: title,
  partKey: '/services/iva/assets/$i/video.mp4',
  subtype: subtype,
  durationMs: seconds == null ? null : seconds * 1000,
  index: i,
);

Map<String, dynamic> _tmdb(
  String name, {
  String type = 'Trailer',
  bool official = true,
  String lang = 'en',
  int size = 1080,
  String published = '2024-03-01T10:00:00.000Z',
  String site = 'YouTube',
  String? key,
}) => {
  'iso_639_1': lang,
  'iso_3166_1': 'US',
  'name': name,
  'key': key ?? 'yt-${name.hashCode.abs()}',
  'site': site,
  'size': size,
  'type': type,
  'official': official,
  'published_at': published,
  'id': 'v${name.hashCode.abs()}',
};

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

  group('length tie-break', () {
    test('among equal trailers, the one closest to 60-180 s wins over the earlier one', () {
      final pick = ClipFilter.filmTrailer([
        _x('Official Trailer', i: 0, seconds: 25),
        _x('Trailer', i: 1, seconds: 140),
        _x('Trailer', i: 2, seconds: 300),
      ]);
      expect(pick?.ratingKey, 'k1');
    });

    test('it only orders: a teaser still beats a trailer of a better length', () {
      final pick = ClipFilter.filmTrailer([
        _x('Official Trailer', i: 0, seconds: 120),
        _x('Teaser', i: 1, seconds: 20),
      ]);
      expect(pick?.title, 'Teaser');
    });

    test('nothing is dropped for its length', () {
      expect(ClipFilter.filmTrailer([_x('Official Trailer', seconds: 900)])?.title, 'Official Trailer');
      expect(ClipFilter.showTrailer([_x('Teaser', seconds: 8)], showTitle: 'Harbor Lights')?.title, 'Teaser');
    });

    test('outside the window, the shorter gap wins', () {
      final pick = ClipFilter.filmTrailer([_x('Trailer', i: 0, seconds: 200), _x('Trailer', i: 1, seconds: 45)]);
      expect(pick?.ratingKey, 'k1', reason: '15 s short of the window beats 20 s over it');
    });

    test('a known length in the window beats an unknown one, which beats one outside it', () {
      expect(ClipFilter.filmTrailer([_x('Trailer', i: 0), _x('Trailer', i: 1, seconds: 90)])?.ratingKey, 'k1');
      expect(ClipFilter.filmTrailer([_x('Trailer', i: 0, seconds: 400), _x('Trailer', i: 1)])?.ratingKey, 'k1');
      expect(
        ClipFilter.filmTrailer([_x('Trailer', i: 0, seconds: 70), _x('Trailer', i: 1, seconds: 170)])?.ratingKey,
        'k0',
      );
    });

    test('show teasers are ordered by length too', () {
      final pick = ClipFilter.showTrailer([
        _x('Teaser', i: 0, seconds: 15),
        _x('Harbor Lights Teaser', i: 1, seconds: 75),
        _x('Official Trailer', i: 2, seconds: 120),
      ], showTitle: 'Harbor Lights');
      expect(pick?.ratingKey, 'k1');
    });

    test('the gap is measured to the nearer edge of the window', () {
      expect(ClipFilter.durationGapMs(null), 0);
      expect(ClipFilter.durationGapMs(60000), 0);
      expect(ClipFilter.durationGapMs(180000), 0);
      expect(ClipFilter.durationGapMs(45000), 15000);
      expect(ClipFilter.durationGapMs(200000), 20000);
    });
  });

  group('TMDB rung rules', () {
    test('official YouTube trailers only; clips, featurettes and other sites are never picked', () {
      expect(
        ClipFilter.tmdbTrailer([
          _tmdb('Fan Trailer', official: false),
          _tmdb('Opening Clip', type: 'Clip'),
          _tmdb('Making Of', type: 'Featurette'),
          _tmdb('Official Trailer', site: 'Vimeo'),
        ], language: 'en'),
        isNull,
      );
    });

    test('a Trailer beats a Teaser', () {
      final pick = ClipFilter.tmdbTrailer([
        _tmdb('Teaser', type: 'Teaser', published: '2023-01-01T00:00:00.000Z'),
        _tmdb('Official Trailer'),
      ], language: 'en');
      expect(pick?.name, 'Official Trailer');
      expect(pick?.type, 'Trailer');
    });

    test('a Teaser is played when there is no Trailer', () {
      expect(ClipFilter.tmdbTrailer([_tmdb('Teaser', type: 'Teaser')], language: 'en')?.type, 'Teaser');
    });

    test("the locale's language first, then any other", () {
      final rows = [
        _tmdb('Trailer (Japanese)', lang: 'ja', published: '2023-01-01T00:00:00.000Z'),
        _tmdb('Official Trailer', lang: 'en'),
      ];
      expect(ClipFilter.tmdbTrailer(rows, language: 'en')?.language, 'en');
      expect(ClipFilter.tmdbTrailer(rows, language: 'EN')?.language, 'en');
      expect(ClipFilter.tmdbTrailer(rows, language: 'fr')?.language, 'ja', reason: 'earliest when none match');
    });

    test('the earliest published_at wins among equals', () {
      final pick = ClipFilter.tmdbTrailer([
        _tmdb('Official Trailer', key: 'late', published: '2024-06-01T00:00:00.000Z'),
        _tmdb('Official Trailer', key: 'early', published: '2024-02-01T00:00:00.000Z'),
        _tmdb('Official Trailer', key: 'undated', published: ''),
      ], language: 'en');
      expect(pick?.key, 'early');
    });

    test('a minimum size drops smaller uploads only when asked', () {
      final rows = [
        _tmdb('Official Trailer', key: 'small', size: 720, published: '2023-01-01T00:00:00.000Z'),
        _tmdb('Official Trailer', key: 'full', size: 1080),
      ];
      expect(ClipFilter.tmdbTrailer(rows, language: 'en')?.key, 'small');
      expect(ClipFilter.tmdbTrailer(rows, language: 'en', minSize: 1080)?.key, 'full');
      expect(ClipFilter.tmdbTrailer([rows.first], language: 'en', minSize: 1080), isNull);
    });

    test('later seasons, final trailers and spots are never picked for a show', () {
      final pick = ClipFilter.tmdbTrailer(
        [
          _tmdb('Season 2 Official Trailer', published: '2020-01-01T00:00:00.000Z'),
          _tmdb('Final Season Trailer', published: '2020-01-02T00:00:00.000Z'),
          _tmdb('TV Spot', published: '2020-01-03T00:00:00.000Z'),
          _tmdb('Harbor Lights | Official Trailer'),
        ],
        language: 'en',
        show: true,
      );
      expect(pick?.name, 'Harbor Lights | Official Trailer');
    });

    test('rows without a key, a type or a map shape are skipped', () {
      expect(
        ClipFilter.tmdbTrailer([
          'not a row',
          {'site': 'YouTube', 'type': 'Trailer', 'official': true},
          {'site': 'YouTube', 'key': 'abc', 'official': true},
        ], language: 'en'),
        isNull,
      );
    });

    test('reads the documented row shape', () {
      final v = TmdbVideo.fromJson(_tmdb('Official Trailer', key: 'abc123', lang: 'EN', size: 2160), 4);
      expect(v?.key, 'abc123');
      expect(v?.language, 'en');
      expect(v?.size, 2160);
      expect(v?.official, isTrue);
      expect(v?.publishedAt, DateTime.utc(2024, 3, 1, 10));
      expect(v?.index, 4);
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
    test('openings without lyrics or subtitles come first; with captions on, those come first (V2-54)', () {
      Map<String, dynamic> anime(List<Map<String, dynamic>> videos) => {
        'animethemes': [
          theme('OP', 1, [
            {'episodes': '1-12', 'videos': videos},
          ]),
        ],
      };
      final videos = [
        {...video('OP1-Lyrics'), 'lyrics': true, 'subbed': false},
        {...video('OP1-Subbed'), 'lyrics': false, 'subbed': true},
        {...video('OP1'), 'lyrics': false, 'subbed': false},
        {...video('OP1-Credits', nc: false), 'lyrics': true},
      ];
      // The captions pref reaches the pick through the playback profile.
      const captioned = ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 1080, captions: true);
      final clean = ClipFilter.firstOpening(anime(videos));
      expect(clean?.url, endsWith('/OP1.webm'));
      expect(clean?.captioned, isFalse);

      final cc = ClipFilter.firstOpening(anime(videos), profile: captioned);
      expect(cc?.url, endsWith('/OP1-Lyrics.webm'));
      expect(cc?.captioned, isTrue);
      expect(
        ClipFilter.firstOpening(anime([videos[1], videos[2]]), profile: captioned)?.url,
        endsWith('/OP1-Subbed.webm'),
        reason: 'subbed counts as captioned',
      );
      expect(
        ClipFilter.firstOpening(anime([videos[2], videos[3]]), profile: captioned)?.url,
        endsWith('/OP1.webm'),
        reason: 'creditless still comes before captions',
      );
    });
  });
}
