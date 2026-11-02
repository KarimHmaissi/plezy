import 'dart:convert';
import 'dart:io';

import 'package:plezy_brain/plezy_brain.dart';
import 'package:test/test.dart';

String _srt(List<(int, int, String)> cues) =>
    [for (final (i, (a, b, t)) in cues.indexed) '${i + 1}\n${_ts(a)} --> ${_ts(b)}\n$t\n'].join('\n');

String _ts(int ms) =>
    '${(ms ~/ 3600000).toString().padLeft(2, '0')}:${(ms ~/ 60000 % 60).toString().padLeft(2, '0')}:'
    '${(ms ~/ 1000 % 60).toString().padLeft(2, '0')},${(ms % 1000).toString().padLeft(3, '0')}';

class _FakeSource implements MediaSource {
  _FakeSource(this.streams);
  final Map<String, List<SubtitleStream>> streams;
  final fetched = <String>[];

  @override
  Future<List<MediaLeaf>> leaves(String id) async => id == 'show'
      ? [
          for (final k in streams.keys)
            MediaLeaf(id: k, type: 'episode', show: 'Show A', season: 1, episode: int.parse(k)),
        ]
      : [MediaLeaf(id: id, type: 'movie')];

  @override
  Future<List<SubtitleStream>> subtitleStreams(String id) async => streams[id] ?? const [];

  @override
  Future<String> fetchSidecar(SubtitleStream stream) async {
    fetched.add(stream.sidecarKey!);
    return _srt([(1000, 3000, '<i>Hello</i> there'), (4000, 5000, '[door slams]'), (6000, 8000, '- Who is it?')]);
  }

  @override
  String? partUrl(String partKey) => 'http://server$partKey?token=secret';
}

void main() {
  test('parses SRT and drops markup, sound cues and dialogue dashes', () {
    final cues = parseSrt(
      _srt([(1000, 3000, '<i>Hello</i> there'), (4000, 5000, '[door slams]'), (6000, 8000, '- Who?')]),
    );
    expect([for (final c in cues) c.text], ['Hello there', 'Who?']);
    expect(cues.first.startMs, 1000);
  });

  test('chunks close at a pause past the minimum, at the maximum, and at long silence', () {
    final cues = [for (var i = 0; i < 20; i++) Cue(i * 5000, i * 5000 + 3000, 'line $i')];
    final chunks = chunkDialogue(cues, minMs: 30000, maxMs: 60000);
    expect(chunks.every((c) => c.endMs - c.startMs <= 60000), isTrue);
    expect(chunkDialogue([const Cue(0, 1000, 'a'), const Cue(30000, 31000, 'b')]), hasLength(2));
  });

  test('prefers a plain English sidecar; never forced or image tracks; embedded only when allowed', () async {
    final source = _FakeSource({
      '1': const [
        SubtitleStream(language: 'eng', codec: 'srt', sidecarKey: '/s/forced', forced: true),
        SubtitleStream(language: 'eng', codec: 'pgs', partKey: '/p', index: 3),
        SubtitleStream(language: 'fra', codec: 'srt', sidecarKey: '/s/fr'),
        SubtitleStream(language: 'eng', codec: 'srt', sidecarKey: '/s/sdh', hearingImpaired: true),
        SubtitleStream(language: 'eng', codec: 'srt', sidecarKey: '/s/en'),
      ],
      '2': const [SubtitleStream(language: 'eng', codec: 'srt', partKey: '/p2', index: 4)],
    });
    final got = await SubtitleReader(source).read('1');
    expect(got?.source, DialogueSource.sidecar);
    expect(source.fetched, ['/s/en']);
    expect(await SubtitleReader(source).read('2'), isNull, reason: 'embedded needs allowEmbedded');

    final calls = <List<String>>[];
    final embedded = await SubtitleReader(
      source,
      allowEmbedded: true,
      run: (exe, args) async {
        calls.add(args);
        return (exitCode: 0, stdout: _srt([(0, 1000, 'From the file')]));
      },
    ).read('2');
    expect(embedded?.source, DialogueSource.embedded);
    expect(calls.single, containsAllInOrder(['-map', '0:4']));
  });

  group('DialogueExportJob', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('brain'));
    tearDown(() => dir.delete(recursive: true));

    test('exports chunks and a manifest, resumes without redoing work, records missing ones', () async {
      final source = _FakeSource({
        '1': const [SubtitleStream(language: 'en', codec: 'srt', sidecarKey: '/s/1')],
        '2': const [],
      });
      final job = DialogueExportJob(source: source, outDir: dir, sleep: (_) async {});

      final first = await job.run(['show']);
      expect(first.toJson(), containsPair('done', 1));
      expect(first.noSubtitles, 1);
      final manifest = [for (final l in File('${dir.path}/manifest.jsonl').readAsLinesSync()) jsonDecode(l)];
      expect(manifest.single, containsPair('id', '1'));
      expect(jsonDecode(File('${dir.path}/1.chunks.json').readAsStringSync()), isNotEmpty);

      final again = await job.run(['show']);
      expect(again.skipped, 2);
      expect(source.fetched, hasLength(1), reason: 'finished leaves are not fetched again');
    });

    test('backs off exponentially when the server is busy and stops after three', () async {
      final sleeps = <Duration>[];
      final job = DialogueExportJob(
        source: _BusySource(),
        outDir: dir,
        sleep: (d) async => sleeps.add(d),
        busyBackoff: const Duration(seconds: 5),
      );
      final summary = await job.run(['movie1']);
      expect(summary.stopped, isTrue);
      expect(summary.busy, 3);
      expect(sleeps, [const Duration(seconds: 5), const Duration(seconds: 10)]);
    });

    test('waits while the host says to pause', () async {
      var pauses = 2;
      final sleeps = <Duration>[];
      final job = DialogueExportJob(
        source: _FakeSource({
          '1': const [SubtitleStream(language: 'en', codec: 'srt', sidecarKey: '/s/1')],
        }),
        outDir: dir,
        shouldPause: () => pauses-- > 0,
        sleep: (d) async => sleeps.add(d),
      );
      await job.run(['movie1']);
      expect(sleeps.where((d) => d == const Duration(seconds: 30)), hasLength(2));
    });
  });
}

class _BusySource extends _FakeSource {
  _BusySource() : super(const {});

  @override
  Future<List<SubtitleStream>> subtitleStreams(String id) async => throw const ServerBusyException(429);
}
