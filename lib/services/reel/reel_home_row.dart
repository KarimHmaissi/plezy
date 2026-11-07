import 'dart:async';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../catalog/home_pins.dart';
import '../customisation/customisation_store.dart';
import 'reel_store.dart';

/// The "From the Reel" row on the TV's Home: the fresh Saves, and first,
/// when they just finished or caught up on a show, one card that opens the
/// "What's next after" deck (D22, build plan §7, [entryItem]).
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
  /// pick to show, or a "What's next after" card ([whatsNext] says whether
  /// there is one). Returns whether the row was added. Safe to call often:
  /// calls run one after another and do nothing once the row was seated.
  static Future<bool> seat({
    bool? onTv,
    CustomisationStore? store,
    HomePinsController? pins,
    ReelStore? reel,
    Future<bool> Function()? whatsNext,
  }) {
    if (!(onTv ?? PlatformDetector.isTV())) {
      appLogger.i('[ReelSave] Home row is seated on the TV, not here');
      return Future.value(false);
    }
    final run = _queue.then(
      (_) => _seat(
        store: store,
        pins: pins ?? HomePinsController.instance,
        reel: reel ?? ReelStore.instance,
        whatsNext: whatsNext,
      ),
    );
    _queue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  static Future<bool> _seat({
    required CustomisationStore? store,
    required HomePinsController pins,
    required ReelStore reel,
    required Future<bool> Function()? whatsNext,
  }) async {
    try {
      final settings = store ?? await Customisation.store;
      if (await settings.readSetting(recheckedKey) == null) {
        await settings.writeSetting(seatedKey, null);
        await settings.writeSetting(recheckedKey, '1');
        appLogger.i('[ReelSave] Home row: seated flag re-checked on this TV');
      }
      if (await settings.readSetting(seatedKey) != null) return false;
      if ((await reel.freshPicks()).isEmpty && !(await whatsNext?.call() ?? false)) return false;
      final added = await pins.insertFirst((id: HomeRowIds.reelPicks, title: title, sources: const <String>[]));
      await settings.writeSetting(seatedKey, '1');
      appLogger.i('[ReelSave] Home row ${added ? 'seated first' : 'already on Home'}');
      return added;
    } catch (e) {
      appLogger.w('[ReelSave] Home row could not be seated', error: e);
      return false;
    }
  }

  /// What the row shows right now (the "What's next after" card's show,
  /// [whatsNext], then the fresh picks, newest first), as one string: Home
  /// reloads the row when it changes.
  static Future<String> freshKey({ReelStore? reel, Future<String?> Function()? whatsNext}) async {
    String? next;
    try {
      next = await whatsNext?.call();
    } catch (_) {}
    return [
      if (next != null) 'next:$next',
      for (final p in await (reel ?? ReelStore.instance).freshPicks()) '${p.titleId}@${p.at.millisecondsSinceEpoch}',
    ].join(',');
  }

  /// Where an [entryItem] says which deck it opens.
  static const String entryKey = 'reelDeck';

  /// The row's card for a Reel deck: the finished [show]'s poster and art,
  /// named for the deck ("What's next after …"), its summary saying what
  /// OK does. OK opens [deck] ([entryDeck]); the card's menu is the show's.
  static MediaItem entryItem(MediaItem show, {required String deck}) {
    final title = show.title ?? '';
    return MediaItem(
      id: show.id,
      backend: show.backend,
      kind: show.kind,
      title: t.reel.deckNames.whatsNext(title: title),
      summary: t.reel.whatsNextHome(title: title),
      thumbPath: show.thumbPath,
      artPath: show.artPath,
      genres: show.genres,
      libraryId: show.libraryId,
      libraryTitle: show.libraryTitle,
      serverId: show.serverId,
      serverName: show.serverName,
      raw: {entryKey: deck},
    );
  }

  /// The deck an [entryItem] opens, or null for any other item.
  static String? entryDeck(MediaItem item) {
    final deck = item.raw?[entryKey];
    return deck is String && deck.isNotEmpty ? deck : null;
  }
}
