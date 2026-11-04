import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import '../catalog/home_pins.dart';
import '../customisation/customisation_store.dart';

/// One saved answer: the request, the helper's intro, and the picks as
/// playable items with their reasons. A question about the user's history
/// also has a written [answer] (its cards may be empty).
class AiHistoryEntry {
  AiHistoryEntry({
    required this.id,
    required this.request,
    required this.intro,
    required this.createdAt,
    required this.items,
    required this.reasons,
    this.title,
    this.answer,
    this.writeup,
    this.notes = const [],
    this.followUps = const [],
    this.spotlights = const {},
    this.topPicks = const {},
    this.watchState = const {},
    this.headline,
    this.extended = false,
  });

  final String id;
  final String request;

  /// The AI's row name, used instead of [request] for "More like this"
  /// rows (whose request is a long prompt).
  final String? title;
  final String? intro;

  /// Fork: the written answer to a question ("how many…", "what was that
  /// film…"), shown above the cards.
  final String? answer;

  /// Fork: the answer card's text: why these picks and what ties them
  /// together (the [answer] for a history question), with up to two
  /// "worth knowing" notes and refinements to offer next.
  final String? writeup;
  final List<String> notes;
  final List<String> followUps;

  /// Fork: insight on a few picks, and the strongest matches with why, by
  /// [MediaItem.globalKey].
  final Map<String, String> spotlights;
  final Map<String, String> topPicks;

  /// Fork: how far the user got with a pick when it was saved ('watched',
  /// 'inProgress' or 'rewatch': seen more than once), by globalKey.
  final Map<String, String> watchState;

  /// What the answer card shows.
  String? get cardText => writeup ?? answer;

  /// Fork: the gist in a few words, for the folded answer.
  final String? headline;

  /// What the row is called on the AI tab and Home.
  String get label => title ?? request;
  final DateTime createdAt;
  final List<MediaItem> items;

  /// Reason per item, keyed by [MediaItem.globalKey].
  final Map<String, String> reasons;

  /// Grown with Find more: Home's auto-refresh adds to it instead of
  /// replacing it.
  final bool extended;

  /// This entry with [reason] for the item [key].
  AiHistoryEntry withReason(String key, String reason) => AiHistoryEntry(
    id: id,
    request: request,
    title: title,
    intro: intro,
    answer: answer,
    writeup: writeup,
    notes: notes,
    followUps: followUps,
    spotlights: spotlights,
    topPicks: topPicks,
    watchState: watchState,
    headline: headline,
    createdAt: createdAt,
    items: items,
    reasons: {...reasons, key: reason},
    extended: extended,
  );

  /// This entry saved again under [newId] (a suggested list kept).
  AiHistoryEntry copyWithId(String newId) => AiHistoryEntry(
    id: newId,
    request: request,
    title: title,
    intro: intro,
    answer: answer,
    writeup: writeup,
    notes: notes,
    followUps: followUps,
    spotlights: spotlights,
    topPicks: topPicks,
    watchState: watchState,
    headline: headline,
    createdAt: DateTime.now(),
    items: items,
    reasons: reasons,
    extended: extended,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'request': request,
    'title': title,
    'intro': intro,
    if (answer != null) 'answer': answer,
    if (writeup != null) 'writeup': writeup,
    if (notes.isNotEmpty) 'notes': notes,
    if (followUps.isNotEmpty) 'followUps': followUps,
    'headline': ?headline,
    'createdAt': createdAt.millisecondsSinceEpoch,
    if (extended) 'extended': true,
    'items': [
      for (final item in items)
        {
          'item': item.toJson(),
          'reason': reasons[item.globalKey],
          'spotlight': ?spotlights[item.globalKey],
          'top': ?topPicks[item.globalKey],
          'seen': ?watchState[item.globalKey],
        },
    ],
  };

  static AiHistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      final items = <MediaItem>[];
      final reasons = <String, String>{};
      final spotlights = <String, String>{};
      final topPicks = <String, String>{};
      final watchState = <String, String>{};
      for (final raw in (json['items'] as List? ?? const []).whereType<Map>()) {
        final item = MediaItem.fromJson((raw['item'] as Map).cast<String, dynamic>());
        items.add(item);
        if (raw['reason'] is String) reasons[item.globalKey] = raw['reason'] as String;
        if (raw['spotlight'] is String) spotlights[item.globalKey] = raw['spotlight'] as String;
        if (raw['top'] is String) topPicks[item.globalKey] = raw['top'] as String;
        if (raw['seen'] is String) watchState[item.globalKey] = raw['seen'] as String;
      }
      return AiHistoryEntry(
        id: json['id'] as String,
        request: json['request'] as String,
        title: json['title'] as String?,
        intro: json['intro'] as String?,
        answer: json['answer'] as String?,
        writeup: json['writeup'] as String?,
        notes: [...(json['notes'] as List? ?? const []).whereType<String>()],
        followUps: [...(json['followUps'] as List? ?? const []).whereType<String>()],
        spotlights: spotlights,
        topPicks: topPicks,
        watchState: watchState,
        headline: json['headline'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int? ?? 0),
        items: items,
        reasons: reasons,
        extended: json['extended'] == true,
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

  /// Most picks one answer keeps after Find more.
  static const int maxItemsPerEntry = 200;
  static const String _indexKey = 'ai.history.index';
  static String _entryKey(String id) => 'ai.history.$id';

  /// The id of the last answer replaced (Refresh or auto-refresh), so Home
  /// and the AI tab can show the new picks.
  static final ValueNotifier<String?> replaced = ValueNotifier(null);

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
  static Future<void> replace(AiHistoryEntry entry) async {
    await (await Customisation.store).writeSetting(_entryKey(entry.id), jsonEncode(entry.toJson()));
    replaced.value = null;
    replaced.value = entry.id;
  }

  /// The setting key prefix of saved answers (`ai.history.<id>`).
  static const String entryKeyPrefix = 'ai.history.';

  /// After a catch-up sync took answers from another device ([added]) and
  /// removals ([removed]), by id: put them into the order, newest first.
  static Future<void> mergeSynced({required Set<String> added, required Set<String> removed}) async {
    if (added.isEmpty && removed.isEmpty) return;
    final store = await Customisation.store;
    final ids = {...await _ids(), ...added}..removeAll(removed);
    final entries = <({String id, DateTime createdAt})>[];
    for (final id in ids) {
      final raw = await store.readSetting(_entryKey(id));
      final entry = raw == null ? null : AiHistoryEntry.fromJson(jsonDecode(raw));
      if (entry != null) entries.add((id: id, createdAt: entry.createdAt));
    }
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await store.writeSetting(_indexKey, jsonEncode([for (final e in entries) e.id]));
  }

  static Future<void> remove(String id) async {
    final store = await Customisation.store;
    await store.writeSetting(_entryKey(id), null);
    await store.writeSetting(_indexKey, jsonEncode((await _ids()).where((i) => i != id).toList()));
  }
}
