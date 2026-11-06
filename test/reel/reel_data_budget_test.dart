import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/reel_data_budget.dart';
import 'package:plezy/services/settings_service.dart';

void main() {
  test('off mobile data every choice plays as on Wi-Fi', () {
    for (final pref in ReelCellular.values) {
      expect(ReelDataBudget.of(pref, metered: false), ReelDataBudget.full);
    }
  });

  test('on mobile data the pref decides', () {
    expect(ReelDataBudget.of(ReelCellular.normal, metered: true), ReelDataBudget.full);
    expect(ReelDataBudget.of(ReelCellular.dataSaver, metered: true), ReelDataBudget.saver);
    expect(ReelDataBudget.of(ReelCellular.stillsOnly, metered: true), ReelDataBudget.stills);
  });

  test('Data saver is the default', () {
    expect(SettingsService.reelCellular.resolvedDefault, ReelCellular.dataSaver);
  });

  test('Data saver keeps the card on screen and the next; Stills only plays no clips', () {
    expect((ReelDataBudget.full.ahead, ReelDataBudget.full.behind), (2, true));
    expect((ReelDataBudget.saver.ahead, ReelDataBudget.saver.behind), (1, false));
    expect(ReelDataBudget.stills.clips, isFalse);
  });
}
