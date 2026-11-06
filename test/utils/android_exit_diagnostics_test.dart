import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/android_exit_diagnostics.dart';
import 'package:plezy/utils/app_logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup phase vocabulary is fixed and elapsed logging is monotonic', () async {
    expect(AndroidStartupPhase.values.map((phase) => phase.id), [
      'native_on_create',
      'dart_main',
      'runApp',
      'first_frame',
      'database_open_started',
      'database_ready',
      'credentials_loaded',
      'binding_started',
      'binding_settled',
      'main_screen',
    ]);
    expect(AndroidUiState.values.map((state) => state.id), ['main_screen', 'player']);

    MemoryLogOutput.clearLogs();
    AndroidExitDiagnostics.markTelemetryReady();
    AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.databaseOpenStarted);
    AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.databaseReady);
    AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.credentialsLoaded);
    await Future<void>.delayed(Duration.zero);

    final messages = MemoryLogOutput.getLogs()
        .map((entry) => entry.message)
        .where((message) => message.startsWith('Startup phase:'))
        .toList()
        .reversed
        .toList();
    expect(messages, hasLength(3));
    expect(messages[0], contains('phase=database_open_started'));
    expect(messages[1], contains('phase=database_ready'));
    expect(messages[2], contains('phase=credentials_loaded'));

    final elapsed = messages
        .map((message) => int.parse(RegExp(r'elapsedMs=(\d+)').firstMatch(message)!.group(1)!))
        .toList();
    expect(elapsed[1], greaterThanOrEqualTo(elapsed[0]));
    expect(elapsed[2], greaterThanOrEqualTo(elapsed[1]));
  });

  test('only failures and exits the viewer noticed become Sentry messages, one per reason', () {
    String? messageFor(String reason, int importance) =>
        AndroidExitDiagnostics.sentryMessageFor({'reason': reason, 'importance': importance});

    // Routine background kills (cached = 400, service = 300) stay local.
    expect(messageFor('low_memory', 400), isNull);
    expect(messageFor('user_requested', 400), isNull);
    expect(messageFor('other', 300), isNull);

    // Failures are reported wherever the process was.
    expect(messageFor('anr', 400), 'Previous Android application exit: anr');
    expect(messageFor('native_crash', 400), 'Previous Android application exit: native_crash');

    // Any kill the viewer could see (foreground = 100) or hear (perceptible = 230).
    expect(messageFor('other', 100), 'Previous Android application exit: other');
    expect(messageFor('low_memory', 230), 'Previous Android application exit: low_memory');

    expect(AndroidExitDiagnostics.sentryMessageFor({'reason': 'anr'}), isNull);
  });

  group('low-memory kill counter', () {
    Map<String, Object?> summary({Object? background = 3, bool firstSummary = false}) => {
      'exitsInHistory': 9,
      'lowMemoryBackground': background,
      'lowMemoryBackgroundNew': 1,
      'lowMemoryForeground': 0,
      'otherBackground': 4,
      'firstSummary': firstSummary,
      'oldestTimestamp': DateTime.utc(2026, 11, 1).millisecondsSinceEpoch,
      'newestTimestamp': DateTime.utc(2026, 11, 5, 21).millisecondsSinceEpoch,
    };

    test('logs one tagged line with the counts since the last launch', () {
      expect(
        AndroidExitDiagnostics.describeLowMemoryKills(summary()),
        '[LmkCounter] background low-memory kills: 3 in history, 1 since last launch; '
        'foreground low-memory=0 other background exits=4 '
        'history=9 exits 2026-11-01T00:00:00.000Z..2026-11-05T21:00:00.000Z',
      );
      expect(AndroidExitDiagnostics.describeLowMemoryKills(summary(firstSummary: true)), contains('1 (first count)'));
    });

    test('drops a malformed or missing summary', () {
      expect(AndroidExitDiagnostics.describeLowMemoryKills(null), isNull);
      expect(AndroidExitDiagnostics.describeLowMemoryKills(summary(background: 'three')), isNull);
      expect(AndroidExitDiagnostics.describeLowMemoryKills(summary(background: -1)), isNull);
      expect(AndroidExitDiagnostics.describeLowMemoryKills({...summary()}..remove('firstSummary')), isNull);
      expect(
        AndroidExitDiagnostics.describeLowMemoryKills({...summary()}..remove('oldestTimestamp')),
        contains('exits none..'),
      );
    });
  });
}
