import 'package:drift/drift.dart';

import 'index_database.dart';

/// A Plex `Metadata` map from a library listing as an index row.
IndexTitlesCompanion indexRowFromPlex(
  Map<String, dynamic> m, {
  required String serverId,
  required String serverName,
  required String libraryKey,
  required String libraryTitle,
}) {
  String? str(String key) {
    final v = m[key];
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  int? integer(String key) {
    final v = m[key];
    return v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));
  }

  double? real(String key) {
    final v = m[key];
    return v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
  }

  String tags(String key, {int? limit}) {
    final list = m[key];
    if (list is! List) return '';
    final names = [
      for (final t in list)
        if (t is Map && t['tag'] is String) (t['tag'] as String).replaceAll('|', '/'),
    ];
    return (limit == null ? names : names.take(limit)).join('|');
  }

  String? externalId(String scheme) {
    final guids = m['Guid'];
    if (guids is! List) return null;
    for (final g in guids) {
      final id = g is Map ? g['id'] : null;
      if (id is String && id.startsWith('$scheme://')) return id.substring(scheme.length + 3);
    }
    return null;
  }

  final ratingKey = str('ratingKey')!;
  final type = str('type') ?? 'movie';
  final title = str('title') ?? '';
  final year = integer('year');
  final imdb = externalId('imdb');
  final tmdb = externalId('tmdb');
  final tvdb = externalId('tvdb');
  final duration = integer('duration');
  return IndexTitlesCompanion.insert(
    id: '$serverId:$ratingKey',
    serverId: serverId,
    serverName: serverName,
    libraryKey: libraryKey,
    libraryTitle: libraryTitle,
    ratingKey: ratingKey,
    type: type,
    title: title,
    originalTitle: Value(str('originalTitle')),
    year: Value(year),
    releaseDate: Value(str('originallyAvailableAt')),
    addedAt: Value(integer('addedAt')),
    updatedAt: Value(integer('updatedAt')),
    durationMinutes: Value(duration == null ? null : (duration / 60000).round()),
    contentRating: Value(str('contentRating')),
    audienceRating: Value(real('audienceRating')),
    criticRating: Value(real('rating')),
    studio: Value(str('studio')),
    summary: Value(str('summary')),
    tagline: Value(str('tagline')),
    genres: Value(tags('Genre')),
    countries: Value(tags('Country')),
    directors: Value(tags('Director')),
    writers: Value(tags('Writer')),
    cast: Value(tags('Role', limit: 8)),
    collections: Value(tags('Collection')),
    imdb: Value(imdb),
    tmdb: Value(tmdb),
    tvdb: Value(tvdb),
    groupKey: titleGroupKey(type: type, title: title, year: year, imdb: imdb, tmdb: tmdb, tvdb: tvdb),
    episodeCount: Value(integer('leafCount')),
    watchedEpisodeCount: Value(integer('viewedLeafCount')),
    viewCount: Value(integer('viewCount')),
    lastViewedAt: Value(integer('lastViewedAt')),
    viewOffsetMs: Value(integer('viewOffset')),
  );
}

/// Groups one film or show across 4K copies and servers: by external id,
/// else by normalised title and year.
String titleGroupKey({
  required String type,
  required String title,
  int? year,
  String? imdb,
  String? tmdb,
  String? tvdb,
}) {
  if (imdb != null) return 'imdb:$imdb';
  if (tmdb != null) return '$type:tmdb:$tmdb';
  if (tvdb != null) return '$type:tvdb:$tvdb';
  final normalised = title.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();
  return '$type:$normalised:${year ?? ''}';
}
