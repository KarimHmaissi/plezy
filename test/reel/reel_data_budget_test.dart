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

  test('the window: on screen first, then ahead, then behind', () {
    expect(ReelDataBudget.full.window(4), [4, 5, 6, 3]);
    expect(ReelDataBudget.saver.window(4), [4, 5]);
    expect(ReelDataBudget.stills.window(4), isEmpty);
  });

  test('only Data saver caps the picture height', () {
    expect(ReelDataBudget.saver.heightCap, ReelDataBudget.dataSaverHeight);
    expect(ReelDataBudget.full.heightCap, isNull);
    expect(ReelDataBudget.stills.heightCap, isNull);
    expect(ReelDataBudget.stills.clips, isFalse);
  });
}
