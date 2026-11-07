import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import 'base_shared_preferences_service.dart';
import 'jellyfin_client.dart';
import 'plex_client.dart';
import 'settings_service.dart' show EpisodePosterMode;

/// Limits of the platform launcher shelf.
abstract final class SystemShelf {
  /// Android TV rejects a Watch Next sync over this many items. Mirrors
  /// `SystemShelfArtworkStore.MAX_ITEMS` in SystemShelfArtworkProvider.kt;
  /// the native side answers "Too many items" to anything longer.
  static const int maxItems = 20;
}

/// A title the viewer saved for later (a Reel Save, V2-42), offered to
/// Android TV's Play Next row as a WATCHLIST entry after Continue Watching.
@immutable
class ShelfSave {
  const ShelfSave({required this.item, required this.savedAt});

  final MediaItem item;

  /// When it was saved: the entry's last-engagement time, unless that would
  /// lift it above a Continue Watching item (see
  /// [SystemShelfService.syncFromContinueWatching]).
  final DateTime savedAt;
}

/// Remembers when each shelf item was first published, so items without a
/// `lastViewedAt` (next-up episodes) keep one engagement time across syncs
/// instead of being re-stamped with "now" every time. Launchers sort the
/// Watch Next row by that time, so re-stamping reshuffled the row.
abstract class ShelfFirstPublishedStore {
  Future<Map<String, int>> load();
  Future<void> save(Map<String, int> firstPublished);
}

/// In-memory [ShelfFirstPublishedStore], for tests.
@visibleForTesting
class MemoryShelfFirstPublishedStore implements ShelfFirstPublishedStore {
  Map<String, int> value = {};

  @override
  Future<Map<String, int>> load() async => Map.of(value);

  @override
  Future<void> save(Map<String, int> firstPublished) async => value = Map.of(firstPublished);
}

class _PrefsShelfFirstPublishedStore implements ShelfFirstPublishedStore {
  static const _key = 'system_shelf_first_published_v1';

  @override
  Future<Map<String, int>> load() async {
    try {
      final raw = (await BaseSharedPreferencesService.sharedCache()).getString(_key);
      if (raw == null) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is num) entry.key as String: (entry.value as num).toInt(),
      };
    } catch (e) {
      appLogger.w('System shelf: could not read first-published times', error: e);
      return {};
    }
  }

  @override
  Future<void> save(Map<String, int> firstPublished) async {
    try {
      await (await BaseSharedPreferencesService.sharedCache()).setString(_key, jsonEncode(firstPublished));
    } catch (e) {
      appLogger.w('System shelf: could not save first-published times', error: e);
    }
  }
}

/// Syncs Continue Watching content to platform launcher surfaces.
///
/// Android uses the Watch Next row. tvOS uses the app's Top Shelf extension.
class SystemShelfService {
  static const int schemaVersion = 3;
  static const MethodChannel _androidChannel = MethodChannel('com.plezy/watch_next');
  static const MethodChannel _tvosChannel = MethodChannel('com.plezy/system_shelf');
  static const bool _tvosBuild = bool.fromEnvironment('TVOS_BUILD');

  static final SystemShelfService _instance = SystemShelfService._internal();
  static SystemShelfService? _testingInstance;
  factory SystemShelfService() => _testingInstance ?? _instance;

  SystemShelfService._internal()
    : _channelOverride = null,
      _supportOverride = null,
      _tvosTargetOverride = null,
      _firstPublishedStore = _PrefsShelfFirstPublishedStore(),
      _clock = DateTime.now;

  @visibleForTesting
  SystemShelfService.forTesting({
    required MethodChannel channel,
    Future<bool> Function()? isSupported,
    bool Function()? isTvosTarget,
    ShelfFirstPublishedStore? firstPublishedStore,
    DateTime Function()? clock,
  }) : _channelOverride = channel,
       _supportOverride = isSupported,
       _tvosTargetOverride = isTvosTarget,
       _firstPublishedStore = firstPublishedStore ?? MemoryShelfFirstPublishedStore(),
       _clock = clock ?? DateTime.now;

  @visibleForTesting
  static void debugOverrideInstance(SystemShelfService? service) {
    _testingInstance = service;
  }

  final MethodChannel? _channelOverride;
  final Future<bool> Function()? _supportOverride;
  final bool Function()? _tvosTargetOverride;
  final ShelfFirstPublishedStore _firstPublishedStore;
  final DateTime Function() _clock;
  Map<String, int>? _firstPublished;

  String? _activeOwner;
  int _generation = 0;
  Future<void> _mutationTail = Future<void>.value();

  @visibleForTesting
  String? get debugActiveOwner => _activeOwner;

  @visibleForTesting
  int get debugGeneration => _generation;

  /// Forgets the owner and drops the mutation queue. Deliberately does not
  /// await the old tail: a widget test's FakeAsync zone ends without
  /// flushing the microtasks that settle a chained future, so the previous
  /// test's final clear would leave a tail that never completes and hang the
  /// next test's setUp. Tests own their channel fakes, so nothing native is
  /// lost by abandoning the chain.
  @visibleForTesting
  void debugReset() {
    _activeOwner = null;
    _generation = 0;
    _mutationTail = Future<void>.value();
    _firstPublished = null;
  }

  /// Whether this process targets the tvOS Top Shelf (as opposed to the
  /// Android Watch Next row). Decides artwork geometry and which native
  /// surface receives server sources.
  bool get _isTvosTarget {
    final override = _tvosTargetOverride;
    if (override != null) return override();
    return Platform.isIOS && (_tvosBuild || PlatformDetector.isAppleTV());
  }

  MethodChannel? get _channel {
    final override = _channelOverride;
    if (override != null) return override;
    if (Platform.isAndroid) return _androidChannel;
    if (_isTvosTarget) return _tvosChannel;
    return null;
  }

  /// Establishes the only owner allowed to publish launcher shelf state.
  ///
  /// Ownership changes are synchronous. Native mutations remain serialized
  /// behind any clear already queued for the previous owner.
  void beginProfileSession(String profileId) {
    if (profileId.isEmpty) {
      throw ArgumentError.value(profileId, 'profileId', 'must not be empty');
    }
    if (_activeOwner == profileId) return;
    _activeOwner = profileId;
    _generation++;
  }

  /// Invalidates [profileId] synchronously, then clears its native shelf after
  /// every already-dispatched mutation has settled.
  Future<void> endProfileSession(String profileId) async {
    if (_activeOwner != profileId) return;
    _activeOwner = null;
    final generation = ++_generation;
    await _enqueueMutation<void>(() async {
      final channel = _channel;
      if (channel == null) return;
      await _invokeGuarded<bool>(
        channel,
        'clear',
        arguments: _envelope(profileId, generation),
        label: 'Failed to clear system shelf',
        severe: true,
      );
    });
  }

  bool _owns(String profileId, int generation) {
    return _activeOwner == profileId && _generation == generation;
  }

  Future<T?> _enqueueMutation<T>(Future<T> Function() mutation) {
    final completer = Completer<T?>();
    _mutationTail = _mutationTail
        .then((_) async {
          try {
            completer.complete(await mutation());
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          appLogger.w('System shelf mutation failed', error: error, stackTrace: stackTrace);
        });
    return completer.future;
  }

  /// Owner-scoped envelope every mutating native call carries.
  static Map<String, dynamic> _envelope(String profileId, int generation, [Map<String, dynamic>? extra]) {
    return {'schemaVersion': schemaVersion, 'ownerId': profileId, 'generation': generation, ...?extra};
  }

  /// Invokes [method] on [channel], logging channel failures under [label] (at
  /// error level when [severe]) and returning null instead of throwing.
  /// Errors that are not channel failures log [failureLabel] when given.
  Future<T?> _invokeGuarded<T>(
    MethodChannel channel,
    String method, {
    Map<String, dynamic>? arguments,
    required String label,
    String? failureLabel,
    bool severe = false,
  }) async {
    final log = severe ? appLogger.e : appLogger.w;
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException catch (e) {
      log('$label: native channel missing', error: e);
    } on PlatformException catch (e) {
      log('$label: native platform error', error: e);
    } catch (e) {
      log(failureLabel ?? label, error: e);
    }
    return null;
  }

  /// Check whether the current platform has a launcher shelf integration.
  Future<bool> isSupported() async {
    final override = _supportOverride;
    if (override != null) return override();
    final channel = _channel;
    if (channel == null) return false;
    return await _invokeGuarded<bool>(
          channel,
          'isSupported',
          label: 'System shelf unsupported',
          failureLabel: 'System shelf unsupported: native support check failed',
        ) ??
        false;
  }

  /// Sync Continue Watching items for the currently active [profileId].
  ///
  /// On Android TV, [saves] (the Reel's fresh Saves, read only once the
  /// launcher shelf is known to be supported) fill the slots Continue
  /// Watching leaves under [SystemShelf.maxItems], as WATCHLIST entries
  /// (D11). A save whose show or film is already in Continue Watching is
  /// skipped. Each one's last-engagement time is its save time, held below
  /// every Continue Watching item: launchers sort the row by that time
  /// alone (Arc reads it `last_engagement_time_utc_millis DESC` and ignores
  /// the type), so a fresh Save would otherwise lead the row.
  Future<bool> syncFromContinueWatching(
    String profileId,
    List<MediaItem> continueWatchingItems,
    MediaServerClient Function(ServerId serverId) getClientForServerId, {
    bool hideSpoilers = false,
    EpisodePosterMode episodePosterMode = EpisodePosterMode.seriesPoster,
    Future<List<ShelfSave>> Function()? saves,
  }) async {
    final channel = _channel;
    if (channel == null || _activeOwner != profileId) return false;
    final generation = _generation;

    // Keep the caller's order: Continue Watching is already recency-sorted
    // and next-up episodes (no lastViewedAt) sit where they belong. Re-sorting
    // here would sink them below the cap. Exact duplicates keep the first.
    final seen = <String>{};
    final items = <Map<String, dynamic>>[];
    for (final item in continueWatchingItems) {
      if (items.length >= SystemShelf.maxItems) break;
      final shelfItem = _convertToShelfItem(
        item,
        getClientForServerId,
        hideSpoilers: hideSpoilers,
        episodePosterMode: episodePosterMode,
      );
      if (seen.add(shelfItem['contentId'] as String)) items.add(shelfItem);
    }
    await _applyStableEngagement(items);
    if (!_owns(profileId, generation)) return false;

    final supported = await isSupported();
    if (!_owns(profileId, generation) || !supported) return false;

    if (saves != null && !_isTvosTarget) {
      List<ShelfSave> found;
      try {
        found = await saves();
      } catch (e) {
        appLogger.w('[ReelShelf] Play Next: saves unavailable', error: e);
        found = const [];
      }
      if (!_owns(profileId, generation)) return false;
      _appendSaves(
        items,
        continueWatchingItems,
        found,
        getClientForServerId,
        hideSpoilers: hideSpoilers,
        episodePosterMode: episodePosterMode,
      );
    }

    final result = await _enqueueMutation<bool>(() async {
      if (!_owns(profileId, generation)) return false;
      return await _invokeGuarded<bool>(
            channel,
            'sync',
            arguments: _envelope(profileId, generation, {'items': items, 'sectionTitle': t.discover.continueWatching}),
            label: 'Failed to sync system shelf',
            severe: true,
          ) ??
          false;
    });
    return result ?? false;
  }

  /// Appends [saves], newest first, as WATCHLIST entries after the
  /// Continue Watching [items], within [SystemShelf.maxItems]. Skips a save
  /// already on the row and a show with an episode in Continue Watching.
  /// Engagement times strictly decrease from below the lowest Continue
  /// Watching one, so every launcher that sorts by time keeps Continue
  /// Watching first and the saves in save order.
  void _appendSaves(
    List<Map<String, dynamic>> items,
    List<MediaItem> continueWatching,
    List<ShelfSave> saves,
    MediaServerClient Function(ServerId serverId) getClientForServerId, {
    required bool hideSpoilers,
    required EpisodePosterMode episodePosterMode,
  }) {
    final continuing = items.length;
    final onRow = {for (final item in items) item['contentId'] as String};
    final showsContinuing = {
      for (final item in continueWatching)
        if (item.kind == MediaKind.episode && item.grandparentId != null)
          _buildContentId(serverIdOrNull(item.serverId), item.grandparentId!),
    };
    int? below;
    for (final item in items) {
      final time = item['lastEngagementTime'] as int;
      below = below == null ? time : math.min(below, time);
    }
    final newestFirst = [...saves]..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    var alreadyOn = 0;
    var overCap = 0;
    for (final save in newestFirst) {
      if (items.length >= SystemShelf.maxItems) {
        overCap++;
        continue;
      }
      final contentId = _buildContentId(serverIdOrNull(save.item.serverId), save.item.id);
      if (onRow.contains(contentId) || showsContinuing.contains(contentId)) {
        alreadyOn++;
        continue;
      }
      final shelfItem = _convertToShelfItem(
        save.item,
        getClientForServerId,
        hideSpoilers: hideSpoilers,
        episodePosterMode: episodePosterMode,
      );
      var engagement = save.savedAt.millisecondsSinceEpoch;
      if (below != null && engagement >= below) engagement = below - 1;
      below = engagement;
      shelfItem
        ..['watchlist'] = true
        ..['lastPlaybackPosition'] = 0
        ..['lastEngagementTime'] = engagement;
      onRow.add(contentId);
      items.add(shelfItem);
    }
    appLogger.i(
      '[ReelShelf] Play Next: $continuing Continue Watching + ${items.length - continuing} saves as WATCHLIST '
      '(of ${saves.length}; $alreadyOn already on the row, $overCap over the ${SystemShelf.maxItems} cap)',
    );
  }

  /// Gives every item without a `lastViewedAt` the time it was first
  /// published, and records that time for items seen for the first time.
  /// A new next-up episode still gets "now", so it leads the row once, and
  /// after that it holds its place. The map is pruned to the current items.
  Future<void> _applyStableEngagement(List<Map<String, dynamic>> items) async {
    final known = _firstPublished ??= await _firstPublishedStore.load();
    final now = _clock().millisecondsSinceEpoch;
    final next = <String, int>{};
    for (final item in items) {
      final contentId = item['contentId'] as String;
      final firstPublished = known[contentId] ?? now;
      next[contentId] = firstPublished;
      item['lastEngagementTime'] ??= firstPublished;
    }
    if (!mapEquals(known, next)) {
      _firstPublished = next;
      await _firstPublishedStore.save(next);
    }
  }

  /// Remove a single launcher shelf item for the current profile owner.
  Future<bool> removeItem(String profileId, ServerId serverId, String ratingKey) async {
    final channel = _channel;
    if (channel == null || _activeOwner != profileId) return false;
    final generation = _generation;
    final result = await _enqueueMutation<bool>(() async {
      if (!_owns(profileId, generation)) return false;
      return await _invokeGuarded<bool>(
            channel,
            'remove',
            arguments: _envelope(profileId, generation, {'contentId': _buildContentId(serverId, ratingKey)}),
            label: 'Failed to remove system shelf item',
            severe: true,
          ) ??
          false;
    });
    return result ?? false;
  }

  /// Publish live server connection sources to the tvOS Top Shelf extension so
  /// it can fetch Continue Watching itself. tvOS-only: Android's Watch Next
  /// row is refreshed by the app process instead, so this is a no-op there.
  Future<bool> syncServerSources(
    String profileId,
    List<MediaServerClient> clients, {
    EpisodePosterMode episodePosterMode = EpisodePosterMode.seriesPoster,
  }) async {
    if (!_isTvosTarget) return false;
    final channel = _channel;
    if (channel == null || _activeOwner != profileId) return false;
    final generation = _generation;

    final servers = clients.map(_describeServerSource).nonNulls.toList(growable: false);
    final result = await _enqueueMutation<bool>(() async {
      if (!_owns(profileId, generation)) return false;
      return await _invokeGuarded<bool>(
            channel,
            'updateSources',
            arguments: _envelope(profileId, generation, {
              'servers': servers,
              'maxItems': 20,
              'sectionTitle': t.discover.continueWatching,
              'episodePoster': episodePosterMode == EpisodePosterMode.seasonPoster ? 'season' : 'series',
            }),
            label: 'Failed to update system shelf sources',
            severe: true,
          ) ??
          false;
    });
    return result ?? false;
  }

  /// The Top Shelf fills 2:3 poster slots, so an episode shows its season
  /// poster only when that is the viewer's episode poster setting. Every
  /// other setting gets the series poster, as in Plex's own client (#2377):
  /// an episode still cannot fill a poster slot.
  static EpisodePosterMode _topShelfPosterMode(EpisodePosterMode mode) =>
      mode == EpisodePosterMode.seasonPoster ? EpisodePosterMode.seasonPoster : EpisodePosterMode.seriesPoster;

  /// Backend-specific escape hatch: the Top Shelf extension talks to servers
  /// directly, which needs the raw connection credentials the neutral
  /// [MediaServerClient] interface deliberately hides. Unknown client types
  /// and clients without a usable base URL or token are skipped.
  static Map<String, dynamic>? _describeServerSource(MediaServerClient client) {
    final String kind;
    final String baseUrl;
    final String? token;
    String? userId;
    if (client is PlexClient) {
      kind = 'plex';
      baseUrl = client.config.baseUrl;
      token = client.config.token;
    } else if (client is JellyfinClient) {
      final connection = client.connection;
      kind = connection.dialect.name;
      baseUrl = connection.baseUrl;
      token = connection.accessToken;
      userId = connection.userId;
    } else {
      return null;
    }
    if (baseUrl.isEmpty || token == null || token.isEmpty) return null;
    return {
      'serverId': client.serverId,
      'kind': kind,
      'name': client.serverName ?? '',
      'baseUrl': baseUrl,
      'token': token,
      'userId': ?userId,
    };
  }

  /// Build a content ID. Format: plezy_{serverId}_{ratingKey}
  static String _buildContentId(ServerId? serverId, String ratingKey) {
    return 'plezy_${serverId ?? 'unknown'}_$ratingKey';
  }

  /// Parse a content ID back to (serverId, ratingKey), or null if invalid.
  static (ServerId serverId, String ratingKey)? parseContentId(String contentId) {
    if (!contentId.startsWith('plezy_')) return null;
    final parts = contentId.substring(6).split('_');
    if (parts.length < 2) return null;
    return (ServerId(parts.first), parts.sublist(1).join('_'));
  }

  Map<String, dynamic> _convertToShelfItem(
    MediaItem item,
    MediaServerClient Function(ServerId serverId) getClientForServerId, {
    required bool hideSpoilers,
    required EpisodePosterMode episodePosterMode,
  }) {
    final contentId = _buildContentId(serverIdOrNull(item.serverId), item.id);

    String? posterSourceUri;
    try {
      if (item.serverId != null) {
        final client = getClientForServerId(ServerId(item.serverId!));
        String? thumbPath;
        if (_isTvosTarget) {
          // The Top Shelf renders 2:3 posters: the series (or season) poster
          // chain, then the item's own thumb. Posters cannot spoil, so the
          // spoiler-safe override does not apply here.
          thumbPath = item.posterThumb(mode: _topShelfPosterMode(episodePosterMode));
          if (thumbPath != null) {
            posterSourceUri = client.thumbnailUrl(thumbPath, width: 600, height: 900);
          }
        } else {
          if (hideSpoilers && item.shouldHideSpoiler) {
            thumbPath = item.spoilerSafeArt;
          }
          thumbPath ??= item.posterThumb(mode: EpisodePosterMode.episodeThumbnail, mixedHubContext: true);
          if (thumbPath != null) {
            // Launcher cards on a 4K TV are drawn at about 720 px wide, so
            // 640x360 art was upscaled and soft.
            posterSourceUri = client.thumbnailUrl(thumbPath, width: 1280, height: 720);
          }
        }
      }
    } catch (_) {
      appLogger.w('Failed to prepare system shelf artwork');
    }

    final String title;
    final String? episodeTitle;
    if (item.kind == MediaKind.episode && item.grandparentTitle != null) {
      title = item.grandparentTitle!;
      episodeTitle = item.title;
    } else {
      title = item.title ?? '';
      episodeTitle = null;
    }

    // Null when never viewed: [_applyStableEngagement] fills in the item's
    // first-published time so it does not change between syncs.
    final lastEngagementTime = item.lastViewedAt != null ? item.lastViewedAt! * 1000 : null;

    return {
      'contentId': contentId,
      'title': title,
      'episodeTitle': episodeTitle,
      'description': item.summary,
      'posterSourceUri': posterSourceUri,
      'type': item.kind.name,
      'duration': item.durationMs ?? 0,
      'lastPlaybackPosition': item.viewOffsetMs ?? 0,
      'lastEngagementTime': lastEngagementTime,
      'seriesTitle': item.grandparentTitle,
      'seasonNumber': item.parentIndex,
      'episodeNumber': item.index,
    };
  }
}
