import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/ai_home_refresher.dart';
import 'package:plezy/services/customisation/customisation_store.dart';

import '../../test_helpers/prefs.dart';

void main() {
  late ForkDatabase db;

  setUp(() {
    resetSharedPreferencesForTest();
    db = ForkDatabase.memory();
    Customisation.debugSetStore(LocalCustomisationStore(db));
  });
  tearDown(() async {
    Customisation.debugSetStore(null);
    await db.close();
  });

  test('auto-refresh is on by default and can be turned off and on', () async {
    expect(await AiHomeRefresher.enabled(), isTrue);
    await AiHomeRefresher.setEnabled(false);
    expect(await AiHomeRefresher.enabled(), isFalse);
    await AiHomeRefresher.setEnabled(true);
    expect(await AiHomeRefresher.enabled(), isTrue);
  });

  test('nothing runs before Home starts it', () async {
    expect(await AiHomeRefresher.check(force: true), 0);
  });
}
