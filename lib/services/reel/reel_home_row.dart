import 'dart:async';

import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../catalog/home_pins.dart';
import '../customisation/customisation_store.dart';
import 'reel_store.dart';

/// The "From the Reel" row on the TV's Home.
///
/// Only the TV seats it. A phone's Home layout syncs as one `home` unit
/// (see [SyncUnits.home]), so a phone that seated the row would replace the
/// TV's whole Home on the next catch-up. A Save on the phone only writes the
/// pick; the TV seats the row when that pick reaches it.
abstract final class ReelHomeRow {
  /// This device only (see [SyncUnits.syncsSetting]): set once the row has
  /// been seated here, so removing it in Manage Home sticks.
  static const String seatedKey = 'reel.homeRowSeated';

  /// This device only: set once [seatedKey] has been re-checked. Until it was
  /// made device-local, [seatedKey] synced, so a phone's Save could have set
  /// it on the TV without the TV ever seating the row.
  static const String recheckedKey = 'reel.homeRowRechecked';

  static String get title => t.reel.homeRow;

  static Future<void> _queue = Future.value();

  /// Puts the row at the top of Home once, on the TV, when there is a fresh
  /// pick to show. Returns whether the row was added. Safe to call often:
  /// calls run one after another and do nothing once the row was seated.
  static Future<bool> seat({bool? onTv, CustomisationStore? store, HomePinsController? pins, ReelStore? reel}) {
    if (!(onTv ?? PlatformDetector.isTV())) {
      appLogger.i('[ReelSave] Home row is seated on the TV, not here');
      return Future.value(false);
    }
    final run = _queue.then(
      (_) => _seat(store: store, pins: pins ?? HomePinsController.instance, reel: reel ?? ReelStore.instance),
    );
    _queue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  static Future<bool> _seat({
    required CustomisationStore? store,
    required HomePinsController pins,
    required ReelStore reel,
  }) async {
    try {
      final settings = store ?? await Customisation.store;
      if (await settings.readSetting(recheckedKey) == null) {
        await settings.writeSetting(seatedKey, null);
        await settings.writeSetting(recheckedKey, '1');
        appLogger.i('[ReelSave] Home row: seated flag re-checked on this TV');
      }
      if (await settings.readSetting(seatedKey) != null) return false;
      if ((await reel.freshPicks()).isEmpty) return false;
      final added = await pins.insertFirst((id: HomeRowIds.reelPicks, title: title, sources: const <String>[]));
      await settings.writeSetting(seatedKey, '1');
      appLogger.i('[ReelSave] Home row ${added ? 'seated first' : 'already on Home'}');
      return added;
    } catch (e) {
      appLogger.w('[ReelSave] Home row could not be seated', error: e);
      return false;
    }
  }

  /// What the row shows right now (fresh picks, newest first), as one
  /// string: Home reloads the row when it changes.
  static Future<String> freshKey({ReelStore? reel}) async => [
    for (final p in await (reel ?? ReelStore.instance).freshPicks()) '${p.titleId}@${p.at.millisecondsSinceEpoch}',
  ].join(',');
}
