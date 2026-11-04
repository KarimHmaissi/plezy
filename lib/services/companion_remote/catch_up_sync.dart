import 'dart:async';

import '../../i18n/strings.g.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../providers/companion_remote_provider.dart';
import '../../utils/app_logger.dart';
import '../../utils/snackbar_helper.dart';
import '../ai/ai_history.dart';
import '../catalog/home_pins.dart';
import '../customisation/customisation_store.dart';
import 'phone_mode.dart';

/// Fork: catch-up sync between a phone working on its own data and the TV it
/// connects to. Each side keeps when every piece of its customisation data
/// last changed (Home, Comfort, Shortlist, each setting such as an AI answer
/// or list; see [SyncUnits]); on connecting, and after any change while
/// connected, the two swap the pieces the other has an older copy of. The
/// newest edit of a piece wins wherever it was made.
///
/// 1. Phone → host: [RemoteCommandType.catchUpOffer] with its stamps.
/// 2. Host → phone: [RemoteCommandType.catchUpReply] with the host's newer
///    pieces and the units it wants.
/// 3. Phone → host: [RemoteCommandType.catchUpPush] with those units.
///
/// A host whose data changes while a phone is connected sends
/// [RemoteCommandType.catchUpNudge]; the phone offers again. A round with
/// nothing newer on either side ends there, so the exchange settles.
abstract final class CatchUp {
  /// Stamps as sent in an offer: unit → [ms, deleted].
  static Map<String, List<Object>> encodeStamps(Map<String, SyncStamp> stamps) => {
    for (final MapEntry(:key, :value) in stamps.entries) key: [value.stamp, value.deleted],
  };

  static Map<String, SyncStamp> decodeStamps(Object? raw) => {
    if (raw is Map)
      for (final MapEntry(:key, :value) in raw.entries)
        if (key is String && value is List && value.isNotEmpty && value.first is int)
          key: (stamp: value.first as int, deleted: value.length > 1 && value[1] == true),
  };

  /// Units where [mine] is newer than [theirs] (or they don't have it).
  static Set<String> newerHere(Map<String, SyncStamp> mine, Map<String, SyncStamp> theirs) => {
    for (final MapEntry(key: unit, value: stamp) in mine.entries)
      if (stamp.stamp > (theirs[unit]?.stamp ?? 0)) unit,
  };

  /// Apply [units] from the other device and refresh what depends on them.
  /// Returns how many pieces were taken.
  static Future<int> take(Map<String, Object?> units) async {
    if (units.isEmpty) return 0;
    final store = await Customisation.store;
    if (store is! LocalCustomisationStore) return 0;
    final taken = await store.applySyncUnits(units);
    if (taken.isEmpty) return 0;

    final added = <String>{};
    final removed = <String>{};
    for (final unit in taken) {
      final key = SyncUnits.settingKey(unit);
      if (key == null || !key.startsWith(AiHistory.entryKeyPrefix)) continue;
      final id = key.substring(AiHistory.entryKeyPrefix.length);
      final raw = units[unit];
      (raw is Map && raw['deleted'] == true ? removed : added).add(id);
    }
    await AiHistory.mergeSynced(added: added, removed: removed);
    if (taken.contains(SyncUnits.home)) await HomePinsController.instance.ensureLoaded(refresh: true);
    Customisation.changed.value++;
    return taken.length;
  }

  static void announce(String? deviceName, int pieces) {
    if (pieces == 0) return;
    appLogger.i('CatchUp: synced $pieces piece(s) with ${deviceName ?? 'the other device'}');
    showMainSnackBar(t.companionRemote.syncedWith(name: deviceName ?? t.companionRemote.unknownDevice));
  }
}

/// Phone side: offers on connecting and after its own changes, takes the
/// host's newer pieces and sends what the host asked for.
class CatchUpClient {
  CatchUpClient._();
  static final CatchUpClient instance = CatchUpClient._();

  CompanionRemoteProvider? _remote;
  StreamSubscription<RemoteCommand>? _sub;
  bool _wasConnected = false;
  Timer? _debounce;

  /// Taking the host's pieces writes locally; those writes must not set off
  /// another offer of their own.
  bool _applying = false;

  bool get _active => PhoneMode.isHandheld && !PhoneMode.mirrorsTv;
  bool get _connected => _remote != null && _remote!.isRemote && _remote!.isConnected;

  void start(CompanionRemoteProvider remote) {
    if (identical(_remote, remote)) return;
    stop();
    _remote = remote;
    remote.addListener(_onRemoteChanged);
    _sub = remote.catchUpCommands.listen((c) => unawaited(_onCommand(c)));
    Customisation.localWrites.addListener(_onLocalWrite);
    _onRemoteChanged();
  }

  void stop() {
    _remote?.removeListener(_onRemoteChanged);
    unawaited(_sub?.cancel());
    _sub = null;
    _remote = null;
    _wasConnected = false;
    _debounce?.cancel();
    Customisation.localWrites.removeListener(_onLocalWrite);
  }

  void _onRemoteChanged() {
    final connected = _connected;
    if (connected && !_wasConnected) unawaited(offer());
    _wasConnected = connected;
  }

  void _onLocalWrite() {
    if (_applying || !_active || !_connected) return;
    // One change (an AI answer, a Home edit) is several writes: offer once.
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => unawaited(offer()));
  }

  Future<void> offer() async {
    if (!_active || !_connected) return;
    try {
      final store = await Customisation.store;
      if (store is! LocalCustomisationStore) return;
      _remote!.sendCommand(
        RemoteCommandType.catchUpOffer,
        data: {'stamps': CatchUp.encodeStamps(await store.readSyncStamps())},
      );
    } catch (e) {
      appLogger.w('CatchUp: offer failed', error: e);
    }
  }

  Future<void> _onCommand(RemoteCommand command) async {
    if (!_active || !_connected) return;
    if (command.type == RemoteCommandType.catchUpNudge) return offer();
    if (command.type != RemoteCommandType.catchUpReply) return;
    final data = command.data ?? const {};
    try {
      final units = (data['units'] as Map?)?.cast<String, Object?>() ?? const {};
      final want = [...(data['want'] as List? ?? const []).whereType<String>()];
      _applying = true;
      final int took;
      try {
        took = await CatchUp.take(units);
      } finally {
        _applying = false;
      }
      var sent = 0;
      if (want.isNotEmpty) {
        final store = await Customisation.store;
        if (store is LocalCustomisationStore) {
          final mine = await store.readSyncUnits(want);
          if (mine.isNotEmpty) {
            _remote!.sendCommand(RemoteCommandType.catchUpPush, data: {'units': mine});
            sent = mine.length;
          }
        }
      }
      CatchUp.announce(_remote?.connectedDevice?.name, took + sent);
    } catch (e) {
      appLogger.w('CatchUp: applying the host\'s data failed', error: e);
    }
  }
}

/// Host side (TV or desktop): answers offers and takes phones' newer pieces.
class CatchUpHost {
  CatchUpHost(this._remote);

  final CompanionRemoteProvider _remote;
  Timer? _debounce;
  bool _applying = false;

  void start() => Customisation.localWrites.addListener(_onLocalWrite);

  void stop() {
    Customisation.localWrites.removeListener(_onLocalWrite);
    _debounce?.cancel();
  }

  bool get _hasPhone => _remote.isHost && _remote.isConnected;

  void _onLocalWrite() {
    if (_applying || !_hasPhone) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () {
      if (_hasPhone) _remote.sendCommand(RemoteCommandType.catchUpNudge);
    });
  }

  Future<void> onOffer(Map<String, dynamic> data) async {
    try {
      final store = await Customisation.store;
      if (store is! LocalCustomisationStore) return;
      final theirs = CatchUp.decodeStamps(data['stamps']);
      final mine = await store.readSyncStamps();
      final send = CatchUp.newerHere(mine, theirs);
      final want = CatchUp.newerHere(theirs, mine);
      if (send.isEmpty && want.isEmpty) return;
      _remote.sendCommand(
        RemoteCommandType.catchUpReply,
        data: {'units': await store.readSyncUnits(send), 'want': want.toList()},
      );
      if (want.isEmpty) CatchUp.announce(_remote.connectedDevice?.name, send.length);
    } catch (e) {
      appLogger.w('CatchUp: answering a phone failed', error: e);
    }
  }

  Future<void> onPush(Map<String, dynamic> data) async {
    try {
      final units = (data['units'] as Map?)?.cast<String, Object?>() ?? const {};
      _applying = true;
      final int took;
      try {
        took = await CatchUp.take(units);
      } finally {
        _applying = false;
      }
      CatchUp.announce(_remote.connectedDevice?.name, took);
    } catch (e) {
      appLogger.w('CatchUp: taking a phone\'s data failed', error: e);
    }
  }
}
