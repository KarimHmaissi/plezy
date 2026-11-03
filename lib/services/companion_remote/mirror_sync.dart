import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/companion_remote/remote_command.dart';
import '../../providers/companion_remote_provider.dart';
import '../../utils/app_logger.dart';
import '../ai/ai_activity.dart';
import '../catalog/home_pins.dart';
import '../comfort/comfort_shows_controller.dart';
import '../customisation/customisation_store.dart';
import '../customisation/mirror_store.dart';

/// Host side of mirroring: connected phones get this device's customisation
/// data (Home, Comfort, Shortlist, AI answers and their settings) on request
/// and after every change, and their edits are applied here. The host is the
/// one copy that counts, so the devices never disagree.
class MirrorHost {
  MirrorHost(this._remote);

  final CompanionRemoteProvider _remote;
  int _rev = 0;
  Timer? _debounce;

  void start() {
    Customisation.localWrites.addListener(_onLocalWrite);
    AiActivity.running.addListener(sendActivity);
  }

  void stop() {
    Customisation.localWrites.removeListener(_onLocalWrite);
    AiActivity.running.removeListener(sendActivity);
    _debounce?.cancel();
  }

  bool get _hasPhone => _remote.isHost && _remote.isConnected;

  void _onLocalWrite() {
    if (!_hasPhone) return;
    // One write (an AI answer, a Home edit) is several rows: send once.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => unawaited(sendSnapshot()));
  }

  Future<void> sendSnapshot() async {
    if (!_hasPhone) return;
    try {
      final data = await (await Customisation.store).exportAll();
      _remote.sendCommand(RemoteCommandType.mirrorSnapshot, data: {'rev': ++_rev, 'data': data});
    } catch (e) {
      appLogger.w('Mirror: snapshot failed', error: e);
    }
  }

  void sendActivity() {
    if (_hasPhone) _remote.sendCommand(RemoteCommandType.aiActivity, data: {'running': AiActivity.running.value});
  }

  /// A phone's edit: apply it to this device's data (which sends everyone
  /// the new snapshot) and reload what's on screen here.
  Future<void> applyWrite(Map<String, dynamic> op) async {
    try {
      final store = await Customisation.store;
      switch (op['op']) {
        case 'setting':
          final key = op['key'];
          if (key is String) await store.writeSetting(key, op['value'] as String?);
        case 'home':
          final home = op['home'];
          if (home is! Map) return;
          await store.writeHomeLayout(
            [
              for (final r in (home['rows'] as List? ?? const []).whereType<Map>())
                (
                  id: r['id'] as String,
                  title: r['title'] as String? ?? r['id'] as String,
                  sources: [...(r['sources'] as List? ?? const []).whereType<String>()],
                ),
            ],
            curated: home['curated'] != false,
            revision: home['revision'] is int ? home['revision'] as int : 0,
          );
          await HomePinsController.instance.ensureLoaded(refresh: true);
        case 'comfortList':
          await ComfortShowsController.applyMirrorEdit(op);
        case 'comfort':
          await store.writeComfortPaused({
            for (final p in (op['paused'] as List? ?? const []).whereType<Map>())
              if (p['traktId'] case final int id) id: p['title'] as String? ?? '',
          });
      }
      Customisation.changed.value++;
    } catch (e) {
      appLogger.w('Mirror: applying an edit from the phone failed', error: e);
    }
  }
}

/// Phone side of mirroring: while it has a TV to mirror, the phone shows the
/// TV's data (kept in a cache file of its own, never in this device's
/// database) and sends edits to the TV. Offline it shows the last snapshot,
/// read-only.
class MirrorClient {
  MirrorClient._();
  static final MirrorClient instance = MirrorClient._();

  CompanionRemoteProvider? _remote;
  StreamSubscription<Map<String, dynamic>>? _sub;
  MirrorCustomisationStore? _store;
  bool _wasConnected = false;

  /// The TV the mirrored data came from.
  String? hostName;

  bool get isMirroring => _store != null;
  bool get canEdit => _remote != null && _remote!.isRemote && _remote!.isConnected;

  Future<void> start(CompanionRemoteProvider remote) async {
    if (identical(_remote, remote)) return;
    ComfortShowsController.sendMirrorEdit = _send;
    ComfortShowsController.mirrorCanEdit = () => canEdit;
    _remote?.removeListener(_onRemoteChanged);
    unawaited(_sub?.cancel());
    _remote = remote;
    remote.addListener(_onRemoteChanged);
    _sub = remote.mirrorSnapshots.listen((d) => unawaited(_onSnapshot(d)));
    if (_store == null) {
      final cached = await readCachedSnapshot();
      if (cached != null && _store == null && identical(_remote, remote)) {
        hostName = cached.host;
        _use(cached.data);
      }
    }
    _onRemoteChanged();
  }

  /// The phone went back to its own data (see `PhoneMode`): stop listening
  /// and forget the TV's data. The cache file stays for a later switch.
  void stop() {
    _remote?.removeListener(_onRemoteChanged);
    unawaited(_sub?.cancel());
    _sub = null;
    _remote = null;
    _store = null;
    _wasConnected = false;
    ComfortShowsController.sendMirrorEdit = null;
    ComfortShowsController.mirrorCanEdit = null;
  }

  void _onRemoteChanged() {
    final remote = _remote;
    if (remote == null) return;
    final connected = canEdit;
    if (connected && !_wasConnected) {
      hostName = remote.connectedDevice?.name ?? hostName;
      remote.sendCommand(RemoteCommandType.mirrorRequest);
    }
    if (connected != _wasConnected) {
      _wasConnected = connected;
      // Screens show or hide the read-only note.
      Customisation.changed.value++;
    }
  }

  bool _send(Map<String, Object?> op) {
    if (!canEdit) return false;
    _remote!.sendCommand(RemoteCommandType.mirrorWrite, data: op);
    return true;
  }

  void _use(Map<String, Object?> data) {
    final store = _store;
    if (store == null) {
      _store = MirrorCustomisationStore(data, send: _send);
      Customisation.useMirror(_store!);
    } else {
      store.data = data;
      Customisation.changed.value++;
    }
    unawaited(HomePinsController.instance.ensureLoaded(refresh: true));
  }

  Future<void> _onSnapshot(Map<String, dynamic> snapshot) async {
    final data = snapshot['data'];
    if (data is! Map || _remote == null) return;
    hostName = _remote?.connectedDevice?.name ?? hostName;
    _use(data.cast<String, Object?>());
    await _writeCache(data);
  }

  static Future<File> _cacheFile() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'tv_mirror.json'));

  Future<void> _writeCache(Map<dynamic, dynamic> data) async {
    try {
      await (await _cacheFile()).writeAsString(jsonEncode({'host': hostName, 'data': data}));
    } catch (e) {
      appLogger.d('Mirror: caching the snapshot failed', error: e);
    }
  }

  /// The last TV snapshot this phone kept, if any.
  static Future<({String? host, Map<String, Object?> data})?> readCachedSnapshot() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['data'] is! Map) return null;
      return (host: json['host'] as String?, data: (json['data'] as Map).cast<String, Object?>());
    } catch (e) {
      appLogger.d('Mirror: cached snapshot unreadable', error: e);
      return null;
    }
  }
}
