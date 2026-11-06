import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/quit_app_settings_tile.dart';
import 'package:plezy/services/app_exit_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  testWidgets('Quit Plezy calls the real exit, not the warm move to back', (tester) async {
    var exits = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: QuitAppSettingsTile(
              requestExit: ({AppExitApplication? exitApplicationForTesting}) async {
                exits++;
                return true;
              },
            ),
          ),
        ),
      ),
    );

    expect(find.text('Quit Plezy'), findsOneWidget);
    await tester.tap(find.text('Quit Plezy'));
    await tester.pump();
    expect(exits, 1);
  });

  test('is offered only on an Android TV device', () {
    // The test host is not Android, whatever the TV override says.
    expect(QuitAppSettingsTile.isAvailable, isFalse);
  });
}
