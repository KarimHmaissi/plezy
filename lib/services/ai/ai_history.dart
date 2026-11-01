import 'dart:convert';
import 'dart:math';

import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import '../catalog/home_pins.dart';
import '../customisation/customisation_store.dart';

/// One saved answer: the request, the helper's intro, and the picks as
/// playable items with their reasons.
class AiHistoryEntry {
  AiHistoryEntry({
    required this.id,
    required this.request,
    required this.intro,
    required this.createdAt,
    required this.items,
    required this.reasons,
  });

  final String id;
  final String request;
  final String? intro;
  final DateTime createdAt;
  final List<MediaItem> items;

  /// Reason per item, keyed by [MediaItem.globalKey].
  final Map<String, String> reasons;

  Map<String, Object?> toJson() => {
    'id': id,
    'request': request,
    'intro': intro,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'items': [
      for (final item in items) {'item': item.toJson(), 'reason': reasons[item.globalKey]},
    ],
  };

  static AiHistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      final items = <MediaItem>[];
      final reasons = <String, String>{};
      for (final raw in (json['items'] as List? ?? const []).whereType<Map>()) {
        final item = MediaItem.fromJson((raw['item'] as Map).cast<String, dynamic>());
        items.add(item);
        if (raw['reason'] is String) reasons[item.globalKey] = raw['reason'] as String;
      }
      return AiHistoryEntry(
        id: json['id'] as String,
        request: json['request'] as String,
        intro: json['intro'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int? ?? 0),
        items: items,
        reasons: reasons,
      );
    } catch (e) {
      appLogger.d('AI history: unreadable entry', error: e);
      return null;
    }
  }
}

/// Every request made on the AI tab, newest first, kept in the fork's local
/// database (so it's in Backup & transfer). Up to [maxEntries] are kept;
/// answers added to Home are never trimmed.
/// Each answer is its own setting, so Home can load one without the rest.
abstract final class AiHistory {
  static const int maxEntries = 200;
  static const String _indexKey = 'ai.history.index';
  static String _entryKey(String id) => 'ai.history.$id';

  static Future<List<String>> _ids() async {
    final raw = await (await Customisation.store).readSetting(_indexKey);
    if (raw == null) return [];
    try {
      return [...(jsonDecode(raw) as List).whereType<String>()];
    } catch (_) {
      return [];
    }
  }

  /// How many answers are saved.
  static Future<int> count() async => (await _ids()).length;

  /// Saved answers newest first: [limit] of them from [offset].
  static Future<List<AiHistoryEntry>> page({int offset = 0, required int limit}) async {
    final store = await Customisation.store;
    final out = <AiHistoryEntry>[];
    for (final id in (await _ids()).skip(offset).take(limit)) {
      final raw = await store.readSetting(_entryKey(id));
      final entry = raw == null ? null : AiHistoryEntry.fromJson(jsonDecode(raw));
      if (entry != null) out.add(entry);
    }
    return out;
  }

  static Future<AiHistoryEntry?> get(String id) async {
    final raw = await (await Customisation.store).readSetting(_entryKey(id));
    return raw == null ? null : AiHistoryEntry.fromJson(jsonDecode(raw));
  }

  static String newId() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 20).toRadixString(36)}';

  /// Save [entry] as the newest answer, trimming the oldest beyond
  /// [maxEntries] (except ones on Home).
  static Future<void> add(AiHistoryEntry entry) async {
    final store = await Customisation.store;
    await store.writeSetting(_entryKey(entry.id), jsonEncode(entry.toJson()));
    final ids = [entry.id, ...(await _ids()).where((id) => id != entry.id)];
    final keep = <String>[];
    for (final id in ids) {
      if (keep.length < maxEntries) {
        keep.add(id);
        continue;
      }
      if (HomePinsController.instance.contains(HomeRowIds.ai(id))) {
        keep.add(id);
      } else {
        await store.writeSetting(_entryKey(id), null);
      }
    }
    await store.writeSetting(_indexKey, jsonEncode(keep));
  }

  /// Replace a saved answer in place (Refresh), keeping its position.
  static Future<void> replace(AiHistoryEntry entry) async =>
      (await Customisation.store).writeSetting(_entryKey(entry.id), jsonEncode(entry.toJson()));

  static Future<void> remove(String id) async {
    final store = await Customisation.store;
    await store.writeSetting(_entryKey(id), null);
    await store.writeSetting(_indexKey, jsonEncode((await _ids()).where((i) => i != id).toList()));
  }
}
