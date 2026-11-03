import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/providers/cast_provider.dart';
import 'package:plezy/services/casting/dlna_renderer.dart';
import 'package:plezy/services/casting/google_cast_channel.dart';

void main() {
  group('CastingTitle custom data', () {
    const title = CastingTitle(
      serverId: 'server-1',
      ratingKey: '42',
      title: 'Show',
      subtitle: 'S1 · E2 — Pilot',
      thumbPath: '/library/metadata/42/thumb/1',
      sessionIdentifier: 'session-a',
      transcodeSessionId: 'transcode-a',
    );

    test('round-trips through the JSON the receiver keeps', () {
      final data = jsonDecode(jsonEncode(title.toCustomData())) as Map<String, dynamic>;
      final back = CastingTitle.fromCustomData(data)!;
      expect(back.serverId, 'server-1');
      expect(back.ratingKey, '42');
      expect(back.title, 'Show');
      expect(back.subtitle, 'S1 · E2 — Pilot');
      expect(back.thumbPath, '/library/metadata/42/thumb/1');
      expect(back.sessionIdentifier, 'session-a');
      expect(back.transcodeSessionId, 'transcode-a');
    });

    test('ignores media another sender loaded', () {
      expect(CastingTitle.fromCustomData(null), isNull);
      expect(CastingTitle.fromCustomData({'contentId': 'x'}), isNull);
      expect(CastingTitle.fromCustomData({'plezy': 1, 'server': 's'}), isNull);
    });
  });

  group('CastMediaStatus', () {
    test('parses the native map with its custom data', () {
      final status = CastMediaStatus.fromMap({
        'state': 'paused',
        'positionMs': 61000,
        'durationMs': 122000,
        'customData': jsonEncode({'plezy': 1, 'session': 's'}),
      });
      expect(status.playing, isFalse);
      expect(status.position, const Duration(seconds: 61));
      expect(status.progress, closeTo(0.5, 0.001));
      expect(status.customData?['session'], 's');
    });

    test('does not run past the end while playing', () {
      final status = CastMediaStatus(state: 'playing', positionMs: 10000, durationMs: 10000);
      expect(status.position, const Duration(seconds: 10));
    });

    test('tolerates malformed custom data', () {
      final status = CastMediaStatus.fromMap({'state': 'idle', 'idleReason': 'finished', 'customData': '{not json'});
      expect(status.idle, isTrue);
      expect(status.idleReason, 'finished');
      expect(status.customData, isNull);
    });
  });

  group('DLNA time', () {
    test('formats and parses H:MM:SS', () {
      expect(DlnaPlayer.formatTime(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
      expect(DlnaPlayer.parseTime('1:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(DlnaPlayer.parseTime('0:00:05.5'), const Duration(seconds: 5, milliseconds: 500));
    });

    test('treats NOT_IMPLEMENTED and junk as zero', () {
      expect(DlnaPlayer.parseTime('NOT_IMPLEMENTED'), Duration.zero);
      expect(DlnaPlayer.parseTime(null), Duration.zero);
    });
  });
}
