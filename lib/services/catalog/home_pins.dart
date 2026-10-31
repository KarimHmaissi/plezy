import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/trakt/trakt_user_list.dart';
import '../base_shared_preferences_service.dart';
import '../../utils/app_logger.dart';
import '../trackers/trakt/trakt_client.dart';

/// A Home row: its hub id and title.
typedef HomeRow = ({String id, String title});

/// What the user changed about Home: rows pinned to it (Trakt Lists hub ids,
/// see `TraktListsCatalogSource.listHubId` and its chart ids), in pin order,
/// and rows hidden from it (hub identifiers, see [homeRowKey]).
typedef HomeLayout = ({List<String> pinned, List<String> hidden});

const HomeLayout emptyHomeLayout = (pinned: [], hidden: []);

/// Both live in the description of the private Trakt list "Plezy" (one list
/// slot; its items are reserved for a future shortlist), so they follow the
/// user across devices without a server of our own. Ids are stored compactly
/// so a description holds hundreds of them:
///
///     Plezy app settings [plezy:home=bo,4521837][plezy:hide=cw,home.movies.recent]
///
/// Only the bracketed markers are read; any other description text is kept.
final RegExp _pinnedMarker = RegExp(r'\[plezy:home=([^\]]*)\]');
final RegExp _hiddenMarker = RegExp(r'\[plezy:hide=([^\]]*)\]');
const String _settingsLine = 'Plezy app settings';

/// Chart hub ids and their short codes.
const Map<String, String> _chartCodes = {
  'chart:boxoffice': 'bo',
  'chart:watched:movies': 'wm',
  'chart:watched:shows': 'ws',
  'chart:anticipated:movies': 'am',
  'chart:anticipated:shows': 'as',
};

/// Synthesized Home rows and their short codes.
const Map<String, String> _rowCodes = {'_continue_watching_': 'cw', '_pick_back_up_continue_': 'pb'};

/// Hub id prefix for a list addressed by its Trakt id alone (`/lists/{id}`).
const String anyOwnerListPrefix = 'list:*:';

String _sanitize(String value) => value.replaceAll(RegExp(r'[\[\],;|\s]'), '');

/// Short code for a pinned hub id: a chart code, or a list's Trakt id.
@visibleForTesting
String pinCode(String hubId) {
  final chart = _chartCodes[hubId];
  if (chart != null) return chart;
  final parts = hubId.split(':');
  if (parts.length == 3 && parts[0] == 'list' && int.tryParse(parts[2]) != null) return parts[2];
  return _sanitize(hubId);
}

String _pinHubId(String code) {
  for (final entry in _chartCodes.entries) {
    if (entry.value == code) return entry.key;
  }
  if (int.tryParse(code) != null) return '$anyOwnerListPrefix$code';
  return code;
}

String _hiddenCode(String key) => _rowCodes[key] ?? _sanitize(key);

String _hiddenKey(String code) {
  for (final entry in _rowCodes.entries) {
    if (entry.value == code) return entry.key;
  }
  return code;
}

List<String> _decode(RegExp marker, String description, String Function(String) fromCode) {
  final match = marker.firstMatch(description);
  if (match == null) return const [];
  final seen = <String>{};
  return [
    for (final raw in match.group(1)!.split(','))
      if (raw.trim() case final code when code.isNotEmpty && seen.add(code)) fromCode(code),
  ];
}

HomeLayout parseHomeLayout(String? description) {
  if (description == null) return emptyHomeLayout;
  return (
    pinned: _decode(_pinnedMarker, description, _pinHubId),
    hidden: _decode(_hiddenMarker, description, _hiddenKey),
  );
}

/// [description] with its settings line replaced by one for [layout]; other
/// lines are kept.
String writeHomeLayout(String? description, HomeLayout layout) {
  final kept = [
    for (final line in (description ?? '').split('\n'))
      if (!_pinnedMarker.hasMatch(line) && !_hiddenMarker.hasMatch(line) && line.trim() != _settingsLine) line,
  ];
  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  if (layout.pinned.isNotEmpty || layout.hidden.isNotEmpty) {
    final line = StringBuffer(_settingsLine);
    if (layout.pinned.isNotEmpty) line.write(' [plezy:home=${layout.pinned.map(pinCode).join(',')}]');
    if (layout.hidden.isNotEmpty) line.write('[plezy:hide=${layout.hidden.map(_hiddenCode).join(',')}]');
    kept.add(line.toString());
  }
  return kept.join('\n');
}

/// Whether two pinned hub ids name the same row (a list pinned from Explore
/// carries its owner; one read back from Trakt does not).
bool samePinnedRow(String a, String b) => pinCode(a) == pinCode(b);

/// Key a Home row is hidden by: the hub's identifier, stable across servers
/// and refreshes.
String homeRowKey({String? identifier, required String id}) => identifier ?? id;

/// Thrown when saving needs a new Trakt list but the account is at its
/// personal-list limit.
class HomePinsListLimitException implements Exception {
  final int limit;
  const HomePinsListLimitException(this.limit);
  @override
  String toString() => 'Trakt personal list limit reached ($limit)';
}

/// The rows the user has pinned to or hidden from Home. Trakt (see
/// [parseHomeLayout]) is the source of truth; a local copy lets Home apply
/// the layout immediately and offline, and remembers row titles. The "Plezy"
/// list is only created on the first change, and only if the account has a
/// free list slot.
class HomePinsController extends ChangeNotifier {
  static const String listName = 'Plezy';
  static const String listSlug = 'plezy';
  static const String _cacheKey = 'home_layout_cache_v1';

  HomePinsController(this._client);

  final TraktClient _client;
  TraktUserList? _list;
  HomeLayout _layout = emptyHomeLayout;
  final Map<String, String> _titles = {};
  bool _loaded = false;
  Future<void>? _loading;
  bool _disposed = false;

  /// Pinned rows in pin order, with their titles.
  List<HomeRow> get pins => [for (final id in _layout.pinned) (id: id, title: titleFor(id))];

  /// Hidden rows, most recently hidden last, with their titles.
  List<HomeRow> get hidden => [for (final key in _layout.hidden) (id: key, title: titleFor(key))];

  bool get isLoaded => _loaded;

  /// Characters the settings use in the list description (see [writeHomeLayout]).
  int get descriptionLength => writeHomeLayout(null, _layout).length;

  bool isPinned(String hubId) => _layout.pinned.any((id) => samePinnedRow(id, hubId));
  bool isHidden(String key) => _layout.hidden.contains(key);

  /// The title remembered for a row, or a readable form of its id.
  String titleFor(String id) {
    final title = _titles[id] ?? _titles[pinCode(id)];
    if (title != null) return title;
    return id.replaceAll(RegExp(r'^_+|_+$'), '').replaceAll(RegExp(r'[._]+'), ' ');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Read the layout once (coalesced); [refresh] forces a re-read so changes
  /// made on another device show up.
  Future<void> ensureLoaded({bool refresh = false}) {
    if (_loaded && !refresh) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    if (!_loaded) await _readCache();
    try {
      final lists = await _client.getMyLists();
      _list = lists.where((l) => l.slug == listSlug).firstOrNull ?? lists.where((l) => l.name == listName).firstOrNull;
      _layout = parseHomeLayout(_list?.description);
      _loaded = true;
      _notify();
      await _resolveListTitles();
      await _writeCache();
    } catch (e) {
      appLogger.w('Home pins: load failed', error: e);
    }
  }

  /// Lists pinned on another device have no remembered title; ask Trakt.
  Future<void> _resolveListTitles() async {
    final missing = [
      for (final id in _layout.pinned)
        if (id.startsWith(anyOwnerListPrefix) && !_titles.containsKey(id) && !_titles.containsKey(pinCode(id))) id,
    ];
    if (missing.isEmpty) return;
    await Future.wait([
      for (final id in missing)
        _client
            .getList(int.parse(pinCode(id)))
            .then((list) {
              if (list != null) _titles[pinCode(id)] = list.name;
            })
            .catchError((Object e) => appLogger.d('Home pins: title lookup failed for $id', error: e)),
    ]);
    _notify();
  }

  Future<void> _readCache() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      List<String> strings(Object? value) => value is List ? value.whereType<String>().toList() : const [];
      _layout = (pinned: strings(decoded['pinned']), hidden: strings(decoded['hidden']));
      if (decoded['titles'] case final Map titles) {
        for (final entry in titles.entries) {
          if (entry.key is String && entry.value is String) _titles[entry.key as String] = entry.value as String;
        }
      }
      _loaded = true;
      _notify();
    } catch (e) {
      appLogger.d('Home pins: cache unreadable', error: e);
    }
  }

  Future<void> _writeCache() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString(
        _cacheKey,
        jsonEncode({'pinned': _layout.pinned, 'hidden': _layout.hidden, 'titles': _titles}),
      );
    } catch (e) {
      appLogger.d('Home pins: cache write failed', error: e);
    }
  }

  /// Pin or unpin the row [hubId]. Updates optimistically and rolls back on
  /// failure.
  Future<void> setPinned(String hubId, String title, bool pinned) async {
    await ensureLoaded();
    if (isPinned(hubId) == pinned) return;
    _titles[pinCode(hubId)] = title;
    await _save((
      pinned: pinned
          ? [..._layout.pinned, hubId]
          : [
              for (final id in _layout.pinned)
                if (!samePinnedRow(id, hubId)) id,
            ],
      hidden: _layout.hidden,
    ));
  }

  /// Hide the Home row [key] (see [homeRowKey]) or show it again.
  Future<void> setHidden(String key, String title, bool hidden) async {
    await ensureLoaded();
    if (isHidden(key) == hidden) return;
    _titles[key] = title;
    await _save((
      pinned: _layout.pinned,
      hidden: hidden
          ? [..._layout.hidden, key]
          : [
              for (final k in _layout.hidden)
                if (k != key) k,
            ],
    ));
  }

  Future<void> _save(HomeLayout layout) async {
    final previous = _layout;
    _layout = layout;
    _notify();
    try {
      var list = _list;
      if (list == null) {
        // Creating the list uses one of the account's personal-list slots.
        final limit = await _client.getPersonalListLimit();
        final own = await _client.getMyLists();
        final existing =
            own.where((l) => l.slug == listSlug).firstOrNull ?? own.where((l) => l.name == listName).firstOrNull;
        if (existing != null) {
          list = existing;
        } else {
          if (limit != null && own.length >= limit) throw HomePinsListLimitException(limit);
          list = await _client.createMyList(listName, description: writeHomeLayout(null, layout));
          if (list == null) throw StateError('Trakt did not return the created list');
          _list = list;
          await _writeCache();
          return;
        }
      }
      final description = writeHomeLayout(list.description, layout);
      await _client.updateMyListDescription(list.traktId, description);
      _list = TraktUserList(traktId: list.traktId, slug: list.slug, name: list.name, description: description);
      await _writeCache();
    } catch (e) {
      _layout = previous;
      _notify();
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
