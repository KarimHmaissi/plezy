import 'customisation_store.dart';

/// Thrown by a write while the phone isn't connected to its TV: the mirrored
/// data is read-only then.
class MirrorReadOnlyException implements Exception {
  const MirrorReadOnlyException();
  @override
  String toString() => 'Not connected to the TV';
}

/// A phone's view of its TV's customisation data: reads come from the TV's
/// last snapshot (an export document, see [CustomisationStore.exportAll]);
/// writes go to the TV, which applies them and sends a new snapshot. Each
/// write also lands in [data] at once so the phone doesn't wait for the
/// round trip.
class MirrorCustomisationStore implements CustomisationStore {
  MirrorCustomisationStore(this.data, {required this.send});

  Map<String, Object?> data;

  /// Sends one edit to the TV; false when not connected.
  final bool Function(Map<String, Object?> op) send;

  Map<String, Object?> get _settings => (data['settings'] as Map?)?.cast<String, Object?>() ?? const {};

  void _write(Map<String, Object?> op) {
    if (!send(op)) throw const MirrorReadOnlyException();
  }

  @override
  Future<({List<StoredHomeRow> rows, bool curated, int revision})?> readHomeLayout() async {
    final home = data['homeLayout'];
    if (home is! Map) return null;
    return (
      rows: [
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
  }

  @override
  Future<void> writeHomeLayout(List<StoredHomeRow> rows, {required bool curated, required int revision}) async {
    final home = {
      'curated': curated,
      'revision': revision,
      'rows': [
        for (final r in rows) {'id': r.id, 'title': r.title, 'sources': r.sources},
      ],
    };
    _write({'op': 'home', 'home': home});
    data = {...data, 'homeLayout': home};
  }

  @override
  Future<Map<int, String>> readComfortPaused() async => {
    for (final p in (data['comfortPaused'] as List? ?? const []).whereType<Map>())
      if (p['traktId'] case final int id) id: p['title'] as String? ?? '',
  };

  @override
  Future<void> writeComfortPaused(Map<int, String> paused) async {
    final list = [
      for (final MapEntry(key: id, value: title) in paused.entries) {'traktId': id, 'title': title},
    ];
    _write({'op': 'comfort', 'paused': list});
    data = {...data, 'comfortPaused': list};
  }

  @override
  Future<String?> readSetting(String key) async => _settings[key] as String?;

  @override
  Future<void> writeSetting(String key, String? value) async {
    _write({'op': 'setting', 'key': key, 'value': value});
    final settings = {..._settings};
    if (value == null) {
      settings.remove(key);
    } else {
      settings[key] = value;
    }
    data = {...data, 'settings': settings};
  }

  @override
  Future<Map<String, Object?>> exportAll() async => data;

  /// A phone never replaces its TV's data wholesale.
  @override
  Future<void> importAll(Map<String, Object?> data) async => throw const MirrorReadOnlyException();
}
