// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'index_database.dart';

// ignore_for_file: type=lint
class $IndexTitlesTable extends IndexTitles with TableInfo<$IndexTitlesTable, IndexedTitle> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $IndexTitlesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta('serverId');
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverNameMeta = const VerificationMeta('serverName');
  @override
  late final GeneratedColumn<String> serverName = GeneratedColumn<String>(
    'server_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _libraryKeyMeta = const VerificationMeta('libraryKey');
  @override
  late final GeneratedColumn<String> libraryKey = GeneratedColumn<String>(
    'library_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _libraryTitleMeta = const VerificationMeta('libraryTitle');
  @override
  late final GeneratedColumn<String> libraryTitle = GeneratedColumn<String>(
    'library_title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ratingKeyMeta = const VerificationMeta('ratingKey');
  @override
  late final GeneratedColumn<String> ratingKey = GeneratedColumn<String>(
    'rating_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originalTitleMeta = const VerificationMeta('originalTitle');
  @override
  late final GeneratedColumn<String> originalTitle = GeneratedColumn<String>(
    'original_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
    'year',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _releaseDateMeta = const VerificationMeta('releaseDate');
  @override
  late final GeneratedColumn<String> releaseDate = GeneratedColumn<String>(
    'release_date',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta('addedAt');
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
    'added_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMinutesMeta = const VerificationMeta('durationMinutes');
  @override
  late final GeneratedColumn<int> durationMinutes = GeneratedColumn<int>(
    'duration_minutes',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contentRatingMeta = const VerificationMeta('contentRating');
  @override
  late final GeneratedColumn<String> contentRating = GeneratedColumn<String>(
    'content_rating',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _audienceRatingMeta = const VerificationMeta('audienceRating');
  @override
  late final GeneratedColumn<double> audienceRating = GeneratedColumn<double>(
    'audience_rating',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _criticRatingMeta = const VerificationMeta('criticRating');
  @override
  late final GeneratedColumn<double> criticRating = GeneratedColumn<double>(
    'critic_rating',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _studioMeta = const VerificationMeta('studio');
  @override
  late final GeneratedColumn<String> studio = GeneratedColumn<String>(
    'studio',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta('summary');
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _taglineMeta = const VerificationMeta('tagline');
  @override
  late final GeneratedColumn<String> tagline = GeneratedColumn<String>(
    'tagline',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _genresMeta = const VerificationMeta('genres');
  @override
  late final GeneratedColumn<String> genres = GeneratedColumn<String>(
    'genres',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _countriesMeta = const VerificationMeta('countries');
  @override
  late final GeneratedColumn<String> countries = GeneratedColumn<String>(
    'countries',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _directorsMeta = const VerificationMeta('directors');
  @override
  late final GeneratedColumn<String> directors = GeneratedColumn<String>(
    'directors',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _writersMeta = const VerificationMeta('writers');
  @override
  late final GeneratedColumn<String> writers = GeneratedColumn<String>(
    'writers',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _castMeta = const VerificationMeta('cast');
  @override
  late final GeneratedColumn<String> cast = GeneratedColumn<String>(
    'cast',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _collectionsMeta = const VerificationMeta('collections');
  @override
  late final GeneratedColumn<String> collections = GeneratedColumn<String>(
    'collections',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _imdbMeta = const VerificationMeta('imdb');
  @override
  late final GeneratedColumn<String> imdb = GeneratedColumn<String>(
    'imdb',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tmdbMeta = const VerificationMeta('tmdb');
  @override
  late final GeneratedColumn<String> tmdb = GeneratedColumn<String>(
    'tmdb',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tvdbMeta = const VerificationMeta('tvdb');
  @override
  late final GeneratedColumn<String> tvdb = GeneratedColumn<String>(
    'tvdb',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _groupKeyMeta = const VerificationMeta('groupKey');
  @override
  late final GeneratedColumn<String> groupKey = GeneratedColumn<String>(
    'group_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _episodeCountMeta = const VerificationMeta('episodeCount');
  @override
  late final GeneratedColumn<int> episodeCount = GeneratedColumn<int>(
    'episode_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _watchedEpisodeCountMeta = const VerificationMeta('watchedEpisodeCount');
  @override
  late final GeneratedColumn<int> watchedEpisodeCount = GeneratedColumn<int>(
    'watched_episode_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _viewCountMeta = const VerificationMeta('viewCount');
  @override
  late final GeneratedColumn<int> viewCount = GeneratedColumn<int>(
    'view_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastViewedAtMeta = const VerificationMeta('lastViewedAt');
  @override
  late final GeneratedColumn<int> lastViewedAt = GeneratedColumn<int>(
    'last_viewed_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _viewOffsetMsMeta = const VerificationMeta('viewOffsetMs');
  @override
  late final GeneratedColumn<int> viewOffsetMs = GeneratedColumn<int>(
    'view_offset_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    serverId,
    serverName,
    libraryKey,
    libraryTitle,
    ratingKey,
    type,
    title,
    originalTitle,
    year,
    releaseDate,
    addedAt,
    updatedAt,
    durationMinutes,
    contentRating,
    audienceRating,
    criticRating,
    studio,
    summary,
    tagline,
    genres,
    countries,
    directors,
    writers,
    cast,
    collections,
    imdb,
    tmdb,
    tvdb,
    groupKey,
    episodeCount,
    watchedEpisodeCount,
    viewCount,
    lastViewedAt,
    viewOffsetMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'index_titles';
  @override
  VerificationContext validateIntegrity(Insertable<IndexedTitle> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('server_id')) {
      context.handle(_serverIdMeta, serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta));
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('server_name')) {
      context.handle(_serverNameMeta, serverName.isAcceptableOrUnknown(data['server_name']!, _serverNameMeta));
    } else if (isInserting) {
      context.missing(_serverNameMeta);
    }
    if (data.containsKey('library_key')) {
      context.handle(_libraryKeyMeta, libraryKey.isAcceptableOrUnknown(data['library_key']!, _libraryKeyMeta));
    } else if (isInserting) {
      context.missing(_libraryKeyMeta);
    }
    if (data.containsKey('library_title')) {
      context.handle(_libraryTitleMeta, libraryTitle.isAcceptableOrUnknown(data['library_title']!, _libraryTitleMeta));
    } else if (isInserting) {
      context.missing(_libraryTitleMeta);
    }
    if (data.containsKey('rating_key')) {
      context.handle(_ratingKeyMeta, ratingKey.isAcceptableOrUnknown(data['rating_key']!, _ratingKeyMeta));
    } else if (isInserting) {
      context.missing(_ratingKeyMeta);
    }
    if (data.containsKey('type')) {
      context.handle(_typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('title')) {
      context.handle(_titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('original_title')) {
      context.handle(
        _originalTitleMeta,
        originalTitle.isAcceptableOrUnknown(data['original_title']!, _originalTitleMeta),
      );
    }
    if (data.containsKey('year')) {
      context.handle(_yearMeta, year.isAcceptableOrUnknown(data['year']!, _yearMeta));
    }
    if (data.containsKey('release_date')) {
      context.handle(_releaseDateMeta, releaseDate.isAcceptableOrUnknown(data['release_date']!, _releaseDateMeta));
    }
    if (data.containsKey('added_at')) {
      context.handle(_addedAtMeta, addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta, updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('duration_minutes')) {
      context.handle(
        _durationMinutesMeta,
        durationMinutes.isAcceptableOrUnknown(data['duration_minutes']!, _durationMinutesMeta),
      );
    }
    if (data.containsKey('content_rating')) {
      context.handle(
        _contentRatingMeta,
        contentRating.isAcceptableOrUnknown(data['content_rating']!, _contentRatingMeta),
      );
    }
    if (data.containsKey('audience_rating')) {
      context.handle(
        _audienceRatingMeta,
        audienceRating.isAcceptableOrUnknown(data['audience_rating']!, _audienceRatingMeta),
      );
    }
    if (data.containsKey('critic_rating')) {
      context.handle(_criticRatingMeta, criticRating.isAcceptableOrUnknown(data['critic_rating']!, _criticRatingMeta));
    }
    if (data.containsKey('studio')) {
      context.handle(_studioMeta, studio.isAcceptableOrUnknown(data['studio']!, _studioMeta));
    }
    if (data.containsKey('summary')) {
      context.handle(_summaryMeta, summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta));
    }
    if (data.containsKey('tagline')) {
      context.handle(_taglineMeta, tagline.isAcceptableOrUnknown(data['tagline']!, _taglineMeta));
    }
    if (data.containsKey('genres')) {
      context.handle(_genresMeta, genres.isAcceptableOrUnknown(data['genres']!, _genresMeta));
    }
    if (data.containsKey('countries')) {
      context.handle(_countriesMeta, countries.isAcceptableOrUnknown(data['countries']!, _countriesMeta));
    }
    if (data.containsKey('directors')) {
      context.handle(_directorsMeta, directors.isAcceptableOrUnknown(data['directors']!, _directorsMeta));
    }
    if (data.containsKey('writers')) {
      context.handle(_writersMeta, writers.isAcceptableOrUnknown(data['writers']!, _writersMeta));
    }
    if (data.containsKey('cast')) {
      context.handle(_castMeta, cast.isAcceptableOrUnknown(data['cast']!, _castMeta));
    }
    if (data.containsKey('collections')) {
      context.handle(_collectionsMeta, collections.isAcceptableOrUnknown(data['collections']!, _collectionsMeta));
    }
    if (data.containsKey('imdb')) {
      context.handle(_imdbMeta, imdb.isAcceptableOrUnknown(data['imdb']!, _imdbMeta));
    }
    if (data.containsKey('tmdb')) {
      context.handle(_tmdbMeta, tmdb.isAcceptableOrUnknown(data['tmdb']!, _tmdbMeta));
    }
    if (data.containsKey('tvdb')) {
      context.handle(_tvdbMeta, tvdb.isAcceptableOrUnknown(data['tvdb']!, _tvdbMeta));
    }
    if (data.containsKey('group_key')) {
      context.handle(_groupKeyMeta, groupKey.isAcceptableOrUnknown(data['group_key']!, _groupKeyMeta));
    } else if (isInserting) {
      context.missing(_groupKeyMeta);
    }
    if (data.containsKey('episode_count')) {
      context.handle(_episodeCountMeta, episodeCount.isAcceptableOrUnknown(data['episode_count']!, _episodeCountMeta));
    }
    if (data.containsKey('watched_episode_count')) {
      context.handle(
        _watchedEpisodeCountMeta,
        watchedEpisodeCount.isAcceptableOrUnknown(data['watched_episode_count']!, _watchedEpisodeCountMeta),
      );
    }
    if (data.containsKey('view_count')) {
      context.handle(_viewCountMeta, viewCount.isAcceptableOrUnknown(data['view_count']!, _viewCountMeta));
    }
    if (data.containsKey('last_viewed_at')) {
      context.handle(_lastViewedAtMeta, lastViewedAt.isAcceptableOrUnknown(data['last_viewed_at']!, _lastViewedAtMeta));
    }
    if (data.containsKey('view_offset_ms')) {
      context.handle(_viewOffsetMsMeta, viewOffsetMs.isAcceptableOrUnknown(data['view_offset_ms']!, _viewOffsetMsMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  IndexedTitle map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return IndexedTitle(
      id: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      serverId: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}server_id'])!,
      serverName: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}server_name'])!,
      libraryKey: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}library_key'])!,
      libraryTitle: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}library_title'])!,
      ratingKey: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}rating_key'])!,
      type: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}type'])!,
      title: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      originalTitle: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}original_title']),
      year: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}year']),
      releaseDate: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}release_date']),
      addedAt: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}added_at']),
      updatedAt: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}updated_at']),
      durationMinutes: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}duration_minutes']),
      contentRating: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}content_rating']),
      audienceRating: attachedDatabase.typeMapping.read(DriftSqlType.double, data['${effectivePrefix}audience_rating']),
      criticRating: attachedDatabase.typeMapping.read(DriftSqlType.double, data['${effectivePrefix}critic_rating']),
      studio: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}studio']),
      summary: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}summary']),
      tagline: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}tagline']),
      genres: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}genres'])!,
      countries: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}countries'])!,
      directors: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}directors'])!,
      writers: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}writers'])!,
      cast: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}cast'])!,
      collections: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}collections'])!,
      imdb: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}imdb']),
      tmdb: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}tmdb']),
      tvdb: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}tvdb']),
      groupKey: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}group_key'])!,
      episodeCount: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}episode_count']),
      watchedEpisodeCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}watched_episode_count'],
      ),
      viewCount: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}view_count']),
      lastViewedAt: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}last_viewed_at']),
      viewOffsetMs: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}view_offset_ms']),
    );
  }

  @override
  $IndexTitlesTable createAlias(String alias) {
    return $IndexTitlesTable(attachedDatabase, alias);
  }
}

class IndexedTitle extends DataClass implements Insertable<IndexedTitle> {
  /// `serverId:ratingKey`.
  final String id;
  final String serverId;
  final String serverName;
  final String libraryKey;
  final String libraryTitle;
  final String ratingKey;

  /// `movie` or `show`.
  final String type;
  final String title;
  final String? originalTitle;
  final int? year;

  /// `YYYY-MM-DD` (a show's first air date).
  final String? releaseDate;

  /// Seconds since epoch, as Plex reports them.
  final int? addedAt;
  final int? updatedAt;
  final int? durationMinutes;
  final String? contentRating;

  /// Plex audience rating (usually IMDb) and critic rating, 0-10.
  final double? audienceRating;
  final double? criticRating;
  final String? studio;
  final String? summary;
  final String? tagline;

  /// Lists joined with `|`.
  final String genres;
  final String countries;
  final String directors;
  final String writers;
  final String cast;
  final String collections;
  final String? imdb;
  final String? tmdb;
  final String? tvdb;

  /// The same title across 4K copies and servers (external id, else
  /// title + year).
  final String groupKey;

  /// Shows: episodes and episodes watched.
  final int? episodeCount;
  final int? watchedEpisodeCount;

  /// The signed-in user's watch state.
  final int? viewCount;
  final int? lastViewedAt;
  final int? viewOffsetMs;
  const IndexedTitle({
    required this.id,
    required this.serverId,
    required this.serverName,
    required this.libraryKey,
    required this.libraryTitle,
    required this.ratingKey,
    required this.type,
    required this.title,
    this.originalTitle,
    this.year,
    this.releaseDate,
    this.addedAt,
    this.updatedAt,
    this.durationMinutes,
    this.contentRating,
    this.audienceRating,
    this.criticRating,
    this.studio,
    this.summary,
    this.tagline,
    required this.genres,
    required this.countries,
    required this.directors,
    required this.writers,
    required this.cast,
    required this.collections,
    this.imdb,
    this.tmdb,
    this.tvdb,
    required this.groupKey,
    this.episodeCount,
    this.watchedEpisodeCount,
    this.viewCount,
    this.lastViewedAt,
    this.viewOffsetMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['server_id'] = Variable<String>(serverId);
    map['server_name'] = Variable<String>(serverName);
    map['library_key'] = Variable<String>(libraryKey);
    map['library_title'] = Variable<String>(libraryTitle);
    map['rating_key'] = Variable<String>(ratingKey);
    map['type'] = Variable<String>(type);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || originalTitle != null) {
      map['original_title'] = Variable<String>(originalTitle);
    }
    if (!nullToAbsent || year != null) {
      map['year'] = Variable<int>(year);
    }
    if (!nullToAbsent || releaseDate != null) {
      map['release_date'] = Variable<String>(releaseDate);
    }
    if (!nullToAbsent || addedAt != null) {
      map['added_at'] = Variable<int>(addedAt);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<int>(updatedAt);
    }
    if (!nullToAbsent || durationMinutes != null) {
      map['duration_minutes'] = Variable<int>(durationMinutes);
    }
    if (!nullToAbsent || contentRating != null) {
      map['content_rating'] = Variable<String>(contentRating);
    }
    if (!nullToAbsent || audienceRating != null) {
      map['audience_rating'] = Variable<double>(audienceRating);
    }
    if (!nullToAbsent || criticRating != null) {
      map['critic_rating'] = Variable<double>(criticRating);
    }
    if (!nullToAbsent || studio != null) {
      map['studio'] = Variable<String>(studio);
    }
    if (!nullToAbsent || summary != null) {
      map['summary'] = Variable<String>(summary);
    }
    if (!nullToAbsent || tagline != null) {
      map['tagline'] = Variable<String>(tagline);
    }
    map['genres'] = Variable<String>(genres);
    map['countries'] = Variable<String>(countries);
    map['directors'] = Variable<String>(directors);
    map['writers'] = Variable<String>(writers);
    map['cast'] = Variable<String>(cast);
    map['collections'] = Variable<String>(collections);
    if (!nullToAbsent || imdb != null) {
      map['imdb'] = Variable<String>(imdb);
    }
    if (!nullToAbsent || tmdb != null) {
      map['tmdb'] = Variable<String>(tmdb);
    }
    if (!nullToAbsent || tvdb != null) {
      map['tvdb'] = Variable<String>(tvdb);
    }
    map['group_key'] = Variable<String>(groupKey);
    if (!nullToAbsent || episodeCount != null) {
      map['episode_count'] = Variable<int>(episodeCount);
    }
    if (!nullToAbsent || watchedEpisodeCount != null) {
      map['watched_episode_count'] = Variable<int>(watchedEpisodeCount);
    }
    if (!nullToAbsent || viewCount != null) {
      map['view_count'] = Variable<int>(viewCount);
    }
    if (!nullToAbsent || lastViewedAt != null) {
      map['last_viewed_at'] = Variable<int>(lastViewedAt);
    }
    if (!nullToAbsent || viewOffsetMs != null) {
      map['view_offset_ms'] = Variable<int>(viewOffsetMs);
    }
    return map;
  }

  IndexTitlesCompanion toCompanion(bool nullToAbsent) {
    return IndexTitlesCompanion(
      id: Value(id),
      serverId: Value(serverId),
      serverName: Value(serverName),
      libraryKey: Value(libraryKey),
      libraryTitle: Value(libraryTitle),
      ratingKey: Value(ratingKey),
      type: Value(type),
      title: Value(title),
      originalTitle: originalTitle == null && nullToAbsent ? const Value.absent() : Value(originalTitle),
      year: year == null && nullToAbsent ? const Value.absent() : Value(year),
      releaseDate: releaseDate == null && nullToAbsent ? const Value.absent() : Value(releaseDate),
      addedAt: addedAt == null && nullToAbsent ? const Value.absent() : Value(addedAt),
      updatedAt: updatedAt == null && nullToAbsent ? const Value.absent() : Value(updatedAt),
      durationMinutes: durationMinutes == null && nullToAbsent ? const Value.absent() : Value(durationMinutes),
      contentRating: contentRating == null && nullToAbsent ? const Value.absent() : Value(contentRating),
      audienceRating: audienceRating == null && nullToAbsent ? const Value.absent() : Value(audienceRating),
      criticRating: criticRating == null && nullToAbsent ? const Value.absent() : Value(criticRating),
      studio: studio == null && nullToAbsent ? const Value.absent() : Value(studio),
      summary: summary == null && nullToAbsent ? const Value.absent() : Value(summary),
      tagline: tagline == null && nullToAbsent ? const Value.absent() : Value(tagline),
      genres: Value(genres),
      countries: Value(countries),
      directors: Value(directors),
      writers: Value(writers),
      cast: Value(cast),
      collections: Value(collections),
      imdb: imdb == null && nullToAbsent ? const Value.absent() : Value(imdb),
      tmdb: tmdb == null && nullToAbsent ? const Value.absent() : Value(tmdb),
      tvdb: tvdb == null && nullToAbsent ? const Value.absent() : Value(tvdb),
      groupKey: Value(groupKey),
      episodeCount: episodeCount == null && nullToAbsent ? const Value.absent() : Value(episodeCount),
      watchedEpisodeCount: watchedEpisodeCount == null && nullToAbsent
          ? const Value.absent()
          : Value(watchedEpisodeCount),
      viewCount: viewCount == null && nullToAbsent ? const Value.absent() : Value(viewCount),
      lastViewedAt: lastViewedAt == null && nullToAbsent ? const Value.absent() : Value(lastViewedAt),
      viewOffsetMs: viewOffsetMs == null && nullToAbsent ? const Value.absent() : Value(viewOffsetMs),
    );
  }

  factory IndexedTitle.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return IndexedTitle(
      id: serializer.fromJson<String>(json['id']),
      serverId: serializer.fromJson<String>(json['serverId']),
      serverName: serializer.fromJson<String>(json['serverName']),
      libraryKey: serializer.fromJson<String>(json['libraryKey']),
      libraryTitle: serializer.fromJson<String>(json['libraryTitle']),
      ratingKey: serializer.fromJson<String>(json['ratingKey']),
      type: serializer.fromJson<String>(json['type']),
      title: serializer.fromJson<String>(json['title']),
      originalTitle: serializer.fromJson<String?>(json['originalTitle']),
      year: serializer.fromJson<int?>(json['year']),
      releaseDate: serializer.fromJson<String?>(json['releaseDate']),
      addedAt: serializer.fromJson<int?>(json['addedAt']),
      updatedAt: serializer.fromJson<int?>(json['updatedAt']),
      durationMinutes: serializer.fromJson<int?>(json['durationMinutes']),
      contentRating: serializer.fromJson<String?>(json['contentRating']),
      audienceRating: serializer.fromJson<double?>(json['audienceRating']),
      criticRating: serializer.fromJson<double?>(json['criticRating']),
      studio: serializer.fromJson<String?>(json['studio']),
      summary: serializer.fromJson<String?>(json['summary']),
      tagline: serializer.fromJson<String?>(json['tagline']),
      genres: serializer.fromJson<String>(json['genres']),
      countries: serializer.fromJson<String>(json['countries']),
      directors: serializer.fromJson<String>(json['directors']),
      writers: serializer.fromJson<String>(json['writers']),
      cast: serializer.fromJson<String>(json['cast']),
      collections: serializer.fromJson<String>(json['collections']),
      imdb: serializer.fromJson<String?>(json['imdb']),
      tmdb: serializer.fromJson<String?>(json['tmdb']),
      tvdb: serializer.fromJson<String?>(json['tvdb']),
      groupKey: serializer.fromJson<String>(json['groupKey']),
      episodeCount: serializer.fromJson<int?>(json['episodeCount']),
      watchedEpisodeCount: serializer.fromJson<int?>(json['watchedEpisodeCount']),
      viewCount: serializer.fromJson<int?>(json['viewCount']),
      lastViewedAt: serializer.fromJson<int?>(json['lastViewedAt']),
      viewOffsetMs: serializer.fromJson<int?>(json['viewOffsetMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'serverId': serializer.toJson<String>(serverId),
      'serverName': serializer.toJson<String>(serverName),
      'libraryKey': serializer.toJson<String>(libraryKey),
      'libraryTitle': serializer.toJson<String>(libraryTitle),
      'ratingKey': serializer.toJson<String>(ratingKey),
      'type': serializer.toJson<String>(type),
      'title': serializer.toJson<String>(title),
      'originalTitle': serializer.toJson<String?>(originalTitle),
      'year': serializer.toJson<int?>(year),
      'releaseDate': serializer.toJson<String?>(releaseDate),
      'addedAt': serializer.toJson<int?>(addedAt),
      'updatedAt': serializer.toJson<int?>(updatedAt),
      'durationMinutes': serializer.toJson<int?>(durationMinutes),
      'contentRating': serializer.toJson<String?>(contentRating),
      'audienceRating': serializer.toJson<double?>(audienceRating),
      'criticRating': serializer.toJson<double?>(criticRating),
      'studio': serializer.toJson<String?>(studio),
      'summary': serializer.toJson<String?>(summary),
      'tagline': serializer.toJson<String?>(tagline),
      'genres': serializer.toJson<String>(genres),
      'countries': serializer.toJson<String>(countries),
      'directors': serializer.toJson<String>(directors),
      'writers': serializer.toJson<String>(writers),
      'cast': serializer.toJson<String>(cast),
      'collections': serializer.toJson<String>(collections),
      'imdb': serializer.toJson<String?>(imdb),
      'tmdb': serializer.toJson<String?>(tmdb),
      'tvdb': serializer.toJson<String?>(tvdb),
      'groupKey': serializer.toJson<String>(groupKey),
      'episodeCount': serializer.toJson<int?>(episodeCount),
      'watchedEpisodeCount': serializer.toJson<int?>(watchedEpisodeCount),
      'viewCount': serializer.toJson<int?>(viewCount),
      'lastViewedAt': serializer.toJson<int?>(lastViewedAt),
      'viewOffsetMs': serializer.toJson<int?>(viewOffsetMs),
    };
  }

  IndexedTitle copyWith({
    String? id,
    String? serverId,
    String? serverName,
    String? libraryKey,
    String? libraryTitle,
    String? ratingKey,
    String? type,
    String? title,
    Value<String?> originalTitle = const Value.absent(),
    Value<int?> year = const Value.absent(),
    Value<String?> releaseDate = const Value.absent(),
    Value<int?> addedAt = const Value.absent(),
    Value<int?> updatedAt = const Value.absent(),
    Value<int?> durationMinutes = const Value.absent(),
    Value<String?> contentRating = const Value.absent(),
    Value<double?> audienceRating = const Value.absent(),
    Value<double?> criticRating = const Value.absent(),
    Value<String?> studio = const Value.absent(),
    Value<String?> summary = const Value.absent(),
    Value<String?> tagline = const Value.absent(),
    String? genres,
    String? countries,
    String? directors,
    String? writers,
    String? cast,
    String? collections,
    Value<String?> imdb = const Value.absent(),
    Value<String?> tmdb = const Value.absent(),
    Value<String?> tvdb = const Value.absent(),
    String? groupKey,
    Value<int?> episodeCount = const Value.absent(),
    Value<int?> watchedEpisodeCount = const Value.absent(),
    Value<int?> viewCount = const Value.absent(),
    Value<int?> lastViewedAt = const Value.absent(),
    Value<int?> viewOffsetMs = const Value.absent(),
  }) => IndexedTitle(
    id: id ?? this.id,
    serverId: serverId ?? this.serverId,
    serverName: serverName ?? this.serverName,
    libraryKey: libraryKey ?? this.libraryKey,
    libraryTitle: libraryTitle ?? this.libraryTitle,
    ratingKey: ratingKey ?? this.ratingKey,
    type: type ?? this.type,
    title: title ?? this.title,
    originalTitle: originalTitle.present ? originalTitle.value : this.originalTitle,
    year: year.present ? year.value : this.year,
    releaseDate: releaseDate.present ? releaseDate.value : this.releaseDate,
    addedAt: addedAt.present ? addedAt.value : this.addedAt,
    updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
    durationMinutes: durationMinutes.present ? durationMinutes.value : this.durationMinutes,
    contentRating: contentRating.present ? contentRating.value : this.contentRating,
    audienceRating: audienceRating.present ? audienceRating.value : this.audienceRating,
    criticRating: criticRating.present ? criticRating.value : this.criticRating,
    studio: studio.present ? studio.value : this.studio,
    summary: summary.present ? summary.value : this.summary,
    tagline: tagline.present ? tagline.value : this.tagline,
    genres: genres ?? this.genres,
    countries: countries ?? this.countries,
    directors: directors ?? this.directors,
    writers: writers ?? this.writers,
    cast: cast ?? this.cast,
    collections: collections ?? this.collections,
    imdb: imdb.present ? imdb.value : this.imdb,
    tmdb: tmdb.present ? tmdb.value : this.tmdb,
    tvdb: tvdb.present ? tvdb.value : this.tvdb,
    groupKey: groupKey ?? this.groupKey,
    episodeCount: episodeCount.present ? episodeCount.value : this.episodeCount,
    watchedEpisodeCount: watchedEpisodeCount.present ? watchedEpisodeCount.value : this.watchedEpisodeCount,
    viewCount: viewCount.present ? viewCount.value : this.viewCount,
    lastViewedAt: lastViewedAt.present ? lastViewedAt.value : this.lastViewedAt,
    viewOffsetMs: viewOffsetMs.present ? viewOffsetMs.value : this.viewOffsetMs,
  );
  IndexedTitle copyWithCompanion(IndexTitlesCompanion data) {
    return IndexedTitle(
      id: data.id.present ? data.id.value : this.id,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      serverName: data.serverName.present ? data.serverName.value : this.serverName,
      libraryKey: data.libraryKey.present ? data.libraryKey.value : this.libraryKey,
      libraryTitle: data.libraryTitle.present ? data.libraryTitle.value : this.libraryTitle,
      ratingKey: data.ratingKey.present ? data.ratingKey.value : this.ratingKey,
      type: data.type.present ? data.type.value : this.type,
      title: data.title.present ? data.title.value : this.title,
      originalTitle: data.originalTitle.present ? data.originalTitle.value : this.originalTitle,
      year: data.year.present ? data.year.value : this.year,
      releaseDate: data.releaseDate.present ? data.releaseDate.value : this.releaseDate,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      durationMinutes: data.durationMinutes.present ? data.durationMinutes.value : this.durationMinutes,
      contentRating: data.contentRating.present ? data.contentRating.value : this.contentRating,
      audienceRating: data.audienceRating.present ? data.audienceRating.value : this.audienceRating,
      criticRating: data.criticRating.present ? data.criticRating.value : this.criticRating,
      studio: data.studio.present ? data.studio.value : this.studio,
      summary: data.summary.present ? data.summary.value : this.summary,
      tagline: data.tagline.present ? data.tagline.value : this.tagline,
      genres: data.genres.present ? data.genres.value : this.genres,
      countries: data.countries.present ? data.countries.value : this.countries,
      directors: data.directors.present ? data.directors.value : this.directors,
      writers: data.writers.present ? data.writers.value : this.writers,
      cast: data.cast.present ? data.cast.value : this.cast,
      collections: data.collections.present ? data.collections.value : this.collections,
      imdb: data.imdb.present ? data.imdb.value : this.imdb,
      tmdb: data.tmdb.present ? data.tmdb.value : this.tmdb,
      tvdb: data.tvdb.present ? data.tvdb.value : this.tvdb,
      groupKey: data.groupKey.present ? data.groupKey.value : this.groupKey,
      episodeCount: data.episodeCount.present ? data.episodeCount.value : this.episodeCount,
      watchedEpisodeCount: data.watchedEpisodeCount.present ? data.watchedEpisodeCount.value : this.watchedEpisodeCount,
      viewCount: data.viewCount.present ? data.viewCount.value : this.viewCount,
      lastViewedAt: data.lastViewedAt.present ? data.lastViewedAt.value : this.lastViewedAt,
      viewOffsetMs: data.viewOffsetMs.present ? data.viewOffsetMs.value : this.viewOffsetMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('IndexedTitle(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('serverName: $serverName, ')
          ..write('libraryKey: $libraryKey, ')
          ..write('libraryTitle: $libraryTitle, ')
          ..write('ratingKey: $ratingKey, ')
          ..write('type: $type, ')
          ..write('title: $title, ')
          ..write('originalTitle: $originalTitle, ')
          ..write('year: $year, ')
          ..write('releaseDate: $releaseDate, ')
          ..write('addedAt: $addedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('durationMinutes: $durationMinutes, ')
          ..write('contentRating: $contentRating, ')
          ..write('audienceRating: $audienceRating, ')
          ..write('criticRating: $criticRating, ')
          ..write('studio: $studio, ')
          ..write('summary: $summary, ')
          ..write('tagline: $tagline, ')
          ..write('genres: $genres, ')
          ..write('countries: $countries, ')
          ..write('directors: $directors, ')
          ..write('writers: $writers, ')
          ..write('cast: $cast, ')
          ..write('collections: $collections, ')
          ..write('imdb: $imdb, ')
          ..write('tmdb: $tmdb, ')
          ..write('tvdb: $tvdb, ')
          ..write('groupKey: $groupKey, ')
          ..write('episodeCount: $episodeCount, ')
          ..write('watchedEpisodeCount: $watchedEpisodeCount, ')
          ..write('viewCount: $viewCount, ')
          ..write('lastViewedAt: $lastViewedAt, ')
          ..write('viewOffsetMs: $viewOffsetMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    serverId,
    serverName,
    libraryKey,
    libraryTitle,
    ratingKey,
    type,
    title,
    originalTitle,
    year,
    releaseDate,
    addedAt,
    updatedAt,
    durationMinutes,
    contentRating,
    audienceRating,
    criticRating,
    studio,
    summary,
    tagline,
    genres,
    countries,
    directors,
    writers,
    cast,
    collections,
    imdb,
    tmdb,
    tvdb,
    groupKey,
    episodeCount,
    watchedEpisodeCount,
    viewCount,
    lastViewedAt,
    viewOffsetMs,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is IndexedTitle &&
          other.id == this.id &&
          other.serverId == this.serverId &&
          other.serverName == this.serverName &&
          other.libraryKey == this.libraryKey &&
          other.libraryTitle == this.libraryTitle &&
          other.ratingKey == this.ratingKey &&
          other.type == this.type &&
          other.title == this.title &&
          other.originalTitle == this.originalTitle &&
          other.year == this.year &&
          other.releaseDate == this.releaseDate &&
          other.addedAt == this.addedAt &&
          other.updatedAt == this.updatedAt &&
          other.durationMinutes == this.durationMinutes &&
          other.contentRating == this.contentRating &&
          other.audienceRating == this.audienceRating &&
          other.criticRating == this.criticRating &&
          other.studio == this.studio &&
          other.summary == this.summary &&
          other.tagline == this.tagline &&
          other.genres == this.genres &&
          other.countries == this.countries &&
          other.directors == this.directors &&
          other.writers == this.writers &&
          other.cast == this.cast &&
          other.collections == this.collections &&
          other.imdb == this.imdb &&
          other.tmdb == this.tmdb &&
          other.tvdb == this.tvdb &&
          other.groupKey == this.groupKey &&
          other.episodeCount == this.episodeCount &&
          other.watchedEpisodeCount == this.watchedEpisodeCount &&
          other.viewCount == this.viewCount &&
          other.lastViewedAt == this.lastViewedAt &&
          other.viewOffsetMs == this.viewOffsetMs);
}

class IndexTitlesCompanion extends UpdateCompanion<IndexedTitle> {
  final Value<String> id;
  final Value<String> serverId;
  final Value<String> serverName;
  final Value<String> libraryKey;
  final Value<String> libraryTitle;
  final Value<String> ratingKey;
  final Value<String> type;
  final Value<String> title;
  final Value<String?> originalTitle;
  final Value<int?> year;
  final Value<String?> releaseDate;
  final Value<int?> addedAt;
  final Value<int?> updatedAt;
  final Value<int?> durationMinutes;
  final Value<String?> contentRating;
  final Value<double?> audienceRating;
  final Value<double?> criticRating;
  final Value<String?> studio;
  final Value<String?> summary;
  final Value<String?> tagline;
  final Value<String> genres;
  final Value<String> countries;
  final Value<String> directors;
  final Value<String> writers;
  final Value<String> cast;
  final Value<String> collections;
  final Value<String?> imdb;
  final Value<String?> tmdb;
  final Value<String?> tvdb;
  final Value<String> groupKey;
  final Value<int?> episodeCount;
  final Value<int?> watchedEpisodeCount;
  final Value<int?> viewCount;
  final Value<int?> lastViewedAt;
  final Value<int?> viewOffsetMs;
  final Value<int> rowid;
  const IndexTitlesCompanion({
    this.id = const Value.absent(),
    this.serverId = const Value.absent(),
    this.serverName = const Value.absent(),
    this.libraryKey = const Value.absent(),
    this.libraryTitle = const Value.absent(),
    this.ratingKey = const Value.absent(),
    this.type = const Value.absent(),
    this.title = const Value.absent(),
    this.originalTitle = const Value.absent(),
    this.year = const Value.absent(),
    this.releaseDate = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.durationMinutes = const Value.absent(),
    this.contentRating = const Value.absent(),
    this.audienceRating = const Value.absent(),
    this.criticRating = const Value.absent(),
    this.studio = const Value.absent(),
    this.summary = const Value.absent(),
    this.tagline = const Value.absent(),
    this.genres = const Value.absent(),
    this.countries = const Value.absent(),
    this.directors = const Value.absent(),
    this.writers = const Value.absent(),
    this.cast = const Value.absent(),
    this.collections = const Value.absent(),
    this.imdb = const Value.absent(),
    this.tmdb = const Value.absent(),
    this.tvdb = const Value.absent(),
    this.groupKey = const Value.absent(),
    this.episodeCount = const Value.absent(),
    this.watchedEpisodeCount = const Value.absent(),
    this.viewCount = const Value.absent(),
    this.lastViewedAt = const Value.absent(),
    this.viewOffsetMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  IndexTitlesCompanion.insert({
    required String id,
    required String serverId,
    required String serverName,
    required String libraryKey,
    required String libraryTitle,
    required String ratingKey,
    required String type,
    required String title,
    this.originalTitle = const Value.absent(),
    this.year = const Value.absent(),
    this.releaseDate = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.durationMinutes = const Value.absent(),
    this.contentRating = const Value.absent(),
    this.audienceRating = const Value.absent(),
    this.criticRating = const Value.absent(),
    this.studio = const Value.absent(),
    this.summary = const Value.absent(),
    this.tagline = const Value.absent(),
    this.genres = const Value.absent(),
    this.countries = const Value.absent(),
    this.directors = const Value.absent(),
    this.writers = const Value.absent(),
    this.cast = const Value.absent(),
    this.collections = const Value.absent(),
    this.imdb = const Value.absent(),
    this.tmdb = const Value.absent(),
    this.tvdb = const Value.absent(),
    required String groupKey,
    this.episodeCount = const Value.absent(),
    this.watchedEpisodeCount = const Value.absent(),
    this.viewCount = const Value.absent(),
    this.lastViewedAt = const Value.absent(),
    this.viewOffsetMs = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       serverId = Value(serverId),
       serverName = Value(serverName),
       libraryKey = Value(libraryKey),
       libraryTitle = Value(libraryTitle),
       ratingKey = Value(ratingKey),
       type = Value(type),
       title = Value(title),
       groupKey = Value(groupKey);
  static Insertable<IndexedTitle> custom({
    Expression<String>? id,
    Expression<String>? serverId,
    Expression<String>? serverName,
    Expression<String>? libraryKey,
    Expression<String>? libraryTitle,
    Expression<String>? ratingKey,
    Expression<String>? type,
    Expression<String>? title,
    Expression<String>? originalTitle,
    Expression<int>? year,
    Expression<String>? releaseDate,
    Expression<int>? addedAt,
    Expression<int>? updatedAt,
    Expression<int>? durationMinutes,
    Expression<String>? contentRating,
    Expression<double>? audienceRating,
    Expression<double>? criticRating,
    Expression<String>? studio,
    Expression<String>? summary,
    Expression<String>? tagline,
    Expression<String>? genres,
    Expression<String>? countries,
    Expression<String>? directors,
    Expression<String>? writers,
    Expression<String>? cast,
    Expression<String>? collections,
    Expression<String>? imdb,
    Expression<String>? tmdb,
    Expression<String>? tvdb,
    Expression<String>? groupKey,
    Expression<int>? episodeCount,
    Expression<int>? watchedEpisodeCount,
    Expression<int>? viewCount,
    Expression<int>? lastViewedAt,
    Expression<int>? viewOffsetMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (serverId != null) 'server_id': serverId,
      if (serverName != null) 'server_name': serverName,
      if (libraryKey != null) 'library_key': libraryKey,
      if (libraryTitle != null) 'library_title': libraryTitle,
      if (ratingKey != null) 'rating_key': ratingKey,
      if (type != null) 'type': type,
      if (title != null) 'title': title,
      if (originalTitle != null) 'original_title': originalTitle,
      if (year != null) 'year': year,
      if (releaseDate != null) 'release_date': releaseDate,
      if (addedAt != null) 'added_at': addedAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (durationMinutes != null) 'duration_minutes': durationMinutes,
      if (contentRating != null) 'content_rating': contentRating,
      if (audienceRating != null) 'audience_rating': audienceRating,
      if (criticRating != null) 'critic_rating': criticRating,
      if (studio != null) 'studio': studio,
      if (summary != null) 'summary': summary,
      if (tagline != null) 'tagline': tagline,
      if (genres != null) 'genres': genres,
      if (countries != null) 'countries': countries,
      if (directors != null) 'directors': directors,
      if (writers != null) 'writers': writers,
      if (cast != null) 'cast': cast,
      if (collections != null) 'collections': collections,
      if (imdb != null) 'imdb': imdb,
      if (tmdb != null) 'tmdb': tmdb,
      if (tvdb != null) 'tvdb': tvdb,
      if (groupKey != null) 'group_key': groupKey,
      if (episodeCount != null) 'episode_count': episodeCount,
      if (watchedEpisodeCount != null) 'watched_episode_count': watchedEpisodeCount,
      if (viewCount != null) 'view_count': viewCount,
      if (lastViewedAt != null) 'last_viewed_at': lastViewedAt,
      if (viewOffsetMs != null) 'view_offset_ms': viewOffsetMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  IndexTitlesCompanion copyWith({
    Value<String>? id,
    Value<String>? serverId,
    Value<String>? serverName,
    Value<String>? libraryKey,
    Value<String>? libraryTitle,
    Value<String>? ratingKey,
    Value<String>? type,
    Value<String>? title,
    Value<String?>? originalTitle,
    Value<int?>? year,
    Value<String?>? releaseDate,
    Value<int?>? addedAt,
    Value<int?>? updatedAt,
    Value<int?>? durationMinutes,
    Value<String?>? contentRating,
    Value<double?>? audienceRating,
    Value<double?>? criticRating,
    Value<String?>? studio,
    Value<String?>? summary,
    Value<String?>? tagline,
    Value<String>? genres,
    Value<String>? countries,
    Value<String>? directors,
    Value<String>? writers,
    Value<String>? cast,
    Value<String>? collections,
    Value<String?>? imdb,
    Value<String?>? tmdb,
    Value<String?>? tvdb,
    Value<String>? groupKey,
    Value<int?>? episodeCount,
    Value<int?>? watchedEpisodeCount,
    Value<int?>? viewCount,
    Value<int?>? lastViewedAt,
    Value<int?>? viewOffsetMs,
    Value<int>? rowid,
  }) {
    return IndexTitlesCompanion(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      libraryKey: libraryKey ?? this.libraryKey,
      libraryTitle: libraryTitle ?? this.libraryTitle,
      ratingKey: ratingKey ?? this.ratingKey,
      type: type ?? this.type,
      title: title ?? this.title,
      originalTitle: originalTitle ?? this.originalTitle,
      year: year ?? this.year,
      releaseDate: releaseDate ?? this.releaseDate,
      addedAt: addedAt ?? this.addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      contentRating: contentRating ?? this.contentRating,
      audienceRating: audienceRating ?? this.audienceRating,
      criticRating: criticRating ?? this.criticRating,
      studio: studio ?? this.studio,
      summary: summary ?? this.summary,
      tagline: tagline ?? this.tagline,
      genres: genres ?? this.genres,
      countries: countries ?? this.countries,
      directors: directors ?? this.directors,
      writers: writers ?? this.writers,
      cast: cast ?? this.cast,
      collections: collections ?? this.collections,
      imdb: imdb ?? this.imdb,
      tmdb: tmdb ?? this.tmdb,
      tvdb: tvdb ?? this.tvdb,
      groupKey: groupKey ?? this.groupKey,
      episodeCount: episodeCount ?? this.episodeCount,
      watchedEpisodeCount: watchedEpisodeCount ?? this.watchedEpisodeCount,
      viewCount: viewCount ?? this.viewCount,
      lastViewedAt: lastViewedAt ?? this.lastViewedAt,
      viewOffsetMs: viewOffsetMs ?? this.viewOffsetMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (serverName.present) {
      map['server_name'] = Variable<String>(serverName.value);
    }
    if (libraryKey.present) {
      map['library_key'] = Variable<String>(libraryKey.value);
    }
    if (libraryTitle.present) {
      map['library_title'] = Variable<String>(libraryTitle.value);
    }
    if (ratingKey.present) {
      map['rating_key'] = Variable<String>(ratingKey.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (originalTitle.present) {
      map['original_title'] = Variable<String>(originalTitle.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (releaseDate.present) {
      map['release_date'] = Variable<String>(releaseDate.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<int>(addedAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (durationMinutes.present) {
      map['duration_minutes'] = Variable<int>(durationMinutes.value);
    }
    if (contentRating.present) {
      map['content_rating'] = Variable<String>(contentRating.value);
    }
    if (audienceRating.present) {
      map['audience_rating'] = Variable<double>(audienceRating.value);
    }
    if (criticRating.present) {
      map['critic_rating'] = Variable<double>(criticRating.value);
    }
    if (studio.present) {
      map['studio'] = Variable<String>(studio.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (tagline.present) {
      map['tagline'] = Variable<String>(tagline.value);
    }
    if (genres.present) {
      map['genres'] = Variable<String>(genres.value);
    }
    if (countries.present) {
      map['countries'] = Variable<String>(countries.value);
    }
    if (directors.present) {
      map['directors'] = Variable<String>(directors.value);
    }
    if (writers.present) {
      map['writers'] = Variable<String>(writers.value);
    }
    if (cast.present) {
      map['cast'] = Variable<String>(cast.value);
    }
    if (collections.present) {
      map['collections'] = Variable<String>(collections.value);
    }
    if (imdb.present) {
      map['imdb'] = Variable<String>(imdb.value);
    }
    if (tmdb.present) {
      map['tmdb'] = Variable<String>(tmdb.value);
    }
    if (tvdb.present) {
      map['tvdb'] = Variable<String>(tvdb.value);
    }
    if (groupKey.present) {
      map['group_key'] = Variable<String>(groupKey.value);
    }
    if (episodeCount.present) {
      map['episode_count'] = Variable<int>(episodeCount.value);
    }
    if (watchedEpisodeCount.present) {
      map['watched_episode_count'] = Variable<int>(watchedEpisodeCount.value);
    }
    if (viewCount.present) {
      map['view_count'] = Variable<int>(viewCount.value);
    }
    if (lastViewedAt.present) {
      map['last_viewed_at'] = Variable<int>(lastViewedAt.value);
    }
    if (viewOffsetMs.present) {
      map['view_offset_ms'] = Variable<int>(viewOffsetMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('IndexTitlesCompanion(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('serverName: $serverName, ')
          ..write('libraryKey: $libraryKey, ')
          ..write('libraryTitle: $libraryTitle, ')
          ..write('ratingKey: $ratingKey, ')
          ..write('type: $type, ')
          ..write('title: $title, ')
          ..write('originalTitle: $originalTitle, ')
          ..write('year: $year, ')
          ..write('releaseDate: $releaseDate, ')
          ..write('addedAt: $addedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('durationMinutes: $durationMinutes, ')
          ..write('contentRating: $contentRating, ')
          ..write('audienceRating: $audienceRating, ')
          ..write('criticRating: $criticRating, ')
          ..write('studio: $studio, ')
          ..write('summary: $summary, ')
          ..write('tagline: $tagline, ')
          ..write('genres: $genres, ')
          ..write('countries: $countries, ')
          ..write('directors: $directors, ')
          ..write('writers: $writers, ')
          ..write('cast: $cast, ')
          ..write('collections: $collections, ')
          ..write('imdb: $imdb, ')
          ..write('tmdb: $tmdb, ')
          ..write('tvdb: $tvdb, ')
          ..write('groupKey: $groupKey, ')
          ..write('episodeCount: $episodeCount, ')
          ..write('watchedEpisodeCount: $watchedEpisodeCount, ')
          ..write('viewCount: $viewCount, ')
          ..write('lastViewedAt: $lastViewedAt, ')
          ..write('viewOffsetMs: $viewOffsetMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $IndexLibrariesTable extends IndexLibraries with TableInfo<$IndexLibrariesTable, IndexedLibrary> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $IndexLibrariesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta('serverId');
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverNameMeta = const VerificationMeta('serverName');
  @override
  late final GeneratedColumn<String> serverName = GeneratedColumn<String>(
    'server_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _libraryKeyMeta = const VerificationMeta('libraryKey');
  @override
  late final GeneratedColumn<String> libraryKey = GeneratedColumn<String>(
    'library_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _totalCountMeta = const VerificationMeta('totalCount');
  @override
  late final GeneratedColumn<int> totalCount = GeneratedColumn<int>(
    'total_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _indexedCountMeta = const VerificationMeta('indexedCount');
  @override
  late final GeneratedColumn<int> indexedCount = GeneratedColumn<int>(
    'indexed_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _buildCursorMeta = const VerificationMeta('buildCursor');
  @override
  late final GeneratedColumn<int> buildCursor = GeneratedColumn<int>(
    'build_cursor',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastFullBuildAtMeta = const VerificationMeta('lastFullBuildAt');
  @override
  late final GeneratedColumn<int> lastFullBuildAt = GeneratedColumn<int>(
    'last_full_build_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastUpdateAtMeta = const VerificationMeta('lastUpdateAt');
  @override
  late final GeneratedColumn<int> lastUpdateAt = GeneratedColumn<int>(
    'last_update_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    serverId,
    serverName,
    libraryKey,
    title,
    type,
    totalCount,
    indexedCount,
    buildCursor,
    lastFullBuildAt,
    lastUpdateAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'index_libraries';
  @override
  VerificationContext validateIntegrity(Insertable<IndexedLibrary> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('server_id')) {
      context.handle(_serverIdMeta, serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta));
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('server_name')) {
      context.handle(_serverNameMeta, serverName.isAcceptableOrUnknown(data['server_name']!, _serverNameMeta));
    } else if (isInserting) {
      context.missing(_serverNameMeta);
    }
    if (data.containsKey('library_key')) {
      context.handle(_libraryKeyMeta, libraryKey.isAcceptableOrUnknown(data['library_key']!, _libraryKeyMeta));
    } else if (isInserting) {
      context.missing(_libraryKeyMeta);
    }
    if (data.containsKey('title')) {
      context.handle(_titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('type')) {
      context.handle(_typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('total_count')) {
      context.handle(_totalCountMeta, totalCount.isAcceptableOrUnknown(data['total_count']!, _totalCountMeta));
    }
    if (data.containsKey('indexed_count')) {
      context.handle(_indexedCountMeta, indexedCount.isAcceptableOrUnknown(data['indexed_count']!, _indexedCountMeta));
    }
    if (data.containsKey('build_cursor')) {
      context.handle(_buildCursorMeta, buildCursor.isAcceptableOrUnknown(data['build_cursor']!, _buildCursorMeta));
    }
    if (data.containsKey('last_full_build_at')) {
      context.handle(
        _lastFullBuildAtMeta,
        lastFullBuildAt.isAcceptableOrUnknown(data['last_full_build_at']!, _lastFullBuildAtMeta),
      );
    }
    if (data.containsKey('last_update_at')) {
      context.handle(_lastUpdateAtMeta, lastUpdateAt.isAcceptableOrUnknown(data['last_update_at']!, _lastUpdateAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  IndexedLibrary map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return IndexedLibrary(
      id: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      serverId: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}server_id'])!,
      serverName: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}server_name'])!,
      libraryKey: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}library_key'])!,
      title: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      type: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}type'])!,
      totalCount: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}total_count'])!,
      indexedCount: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}indexed_count'])!,
      buildCursor: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}build_cursor']),
      lastFullBuildAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_full_build_at'],
      ),
      lastUpdateAt: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}last_update_at']),
    );
  }

  @override
  $IndexLibrariesTable createAlias(String alias) {
    return $IndexLibrariesTable(attachedDatabase, alias);
  }
}

class IndexedLibrary extends DataClass implements Insertable<IndexedLibrary> {
  /// `serverId:libraryKey`.
  final String id;
  final String serverId;
  final String serverName;
  final String libraryKey;
  final String title;
  final String type;

  /// Titles Plex reports for the library, and how many are indexed.
  final int totalCount;
  final int indexedCount;

  /// Next page offset while a full build is in progress; null when done.
  final int? buildCursor;

  /// Milliseconds since epoch.
  final int? lastFullBuildAt;
  final int? lastUpdateAt;
  const IndexedLibrary({
    required this.id,
    required this.serverId,
    required this.serverName,
    required this.libraryKey,
    required this.title,
    required this.type,
    required this.totalCount,
    required this.indexedCount,
    this.buildCursor,
    this.lastFullBuildAt,
    this.lastUpdateAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['server_id'] = Variable<String>(serverId);
    map['server_name'] = Variable<String>(serverName);
    map['library_key'] = Variable<String>(libraryKey);
    map['title'] = Variable<String>(title);
    map['type'] = Variable<String>(type);
    map['total_count'] = Variable<int>(totalCount);
    map['indexed_count'] = Variable<int>(indexedCount);
    if (!nullToAbsent || buildCursor != null) {
      map['build_cursor'] = Variable<int>(buildCursor);
    }
    if (!nullToAbsent || lastFullBuildAt != null) {
      map['last_full_build_at'] = Variable<int>(lastFullBuildAt);
    }
    if (!nullToAbsent || lastUpdateAt != null) {
      map['last_update_at'] = Variable<int>(lastUpdateAt);
    }
    return map;
  }

  IndexLibrariesCompanion toCompanion(bool nullToAbsent) {
    return IndexLibrariesCompanion(
      id: Value(id),
      serverId: Value(serverId),
      serverName: Value(serverName),
      libraryKey: Value(libraryKey),
      title: Value(title),
      type: Value(type),
      totalCount: Value(totalCount),
      indexedCount: Value(indexedCount),
      buildCursor: buildCursor == null && nullToAbsent ? const Value.absent() : Value(buildCursor),
      lastFullBuildAt: lastFullBuildAt == null && nullToAbsent ? const Value.absent() : Value(lastFullBuildAt),
      lastUpdateAt: lastUpdateAt == null && nullToAbsent ? const Value.absent() : Value(lastUpdateAt),
    );
  }

  factory IndexedLibrary.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return IndexedLibrary(
      id: serializer.fromJson<String>(json['id']),
      serverId: serializer.fromJson<String>(json['serverId']),
      serverName: serializer.fromJson<String>(json['serverName']),
      libraryKey: serializer.fromJson<String>(json['libraryKey']),
      title: serializer.fromJson<String>(json['title']),
      type: serializer.fromJson<String>(json['type']),
      totalCount: serializer.fromJson<int>(json['totalCount']),
      indexedCount: serializer.fromJson<int>(json['indexedCount']),
      buildCursor: serializer.fromJson<int?>(json['buildCursor']),
      lastFullBuildAt: serializer.fromJson<int?>(json['lastFullBuildAt']),
      lastUpdateAt: serializer.fromJson<int?>(json['lastUpdateAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'serverId': serializer.toJson<String>(serverId),
      'serverName': serializer.toJson<String>(serverName),
      'libraryKey': serializer.toJson<String>(libraryKey),
      'title': serializer.toJson<String>(title),
      'type': serializer.toJson<String>(type),
      'totalCount': serializer.toJson<int>(totalCount),
      'indexedCount': serializer.toJson<int>(indexedCount),
      'buildCursor': serializer.toJson<int?>(buildCursor),
      'lastFullBuildAt': serializer.toJson<int?>(lastFullBuildAt),
      'lastUpdateAt': serializer.toJson<int?>(lastUpdateAt),
    };
  }

  IndexedLibrary copyWith({
    String? id,
    String? serverId,
    String? serverName,
    String? libraryKey,
    String? title,
    String? type,
    int? totalCount,
    int? indexedCount,
    Value<int?> buildCursor = const Value.absent(),
    Value<int?> lastFullBuildAt = const Value.absent(),
    Value<int?> lastUpdateAt = const Value.absent(),
  }) => IndexedLibrary(
    id: id ?? this.id,
    serverId: serverId ?? this.serverId,
    serverName: serverName ?? this.serverName,
    libraryKey: libraryKey ?? this.libraryKey,
    title: title ?? this.title,
    type: type ?? this.type,
    totalCount: totalCount ?? this.totalCount,
    indexedCount: indexedCount ?? this.indexedCount,
    buildCursor: buildCursor.present ? buildCursor.value : this.buildCursor,
    lastFullBuildAt: lastFullBuildAt.present ? lastFullBuildAt.value : this.lastFullBuildAt,
    lastUpdateAt: lastUpdateAt.present ? lastUpdateAt.value : this.lastUpdateAt,
  );
  IndexedLibrary copyWithCompanion(IndexLibrariesCompanion data) {
    return IndexedLibrary(
      id: data.id.present ? data.id.value : this.id,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      serverName: data.serverName.present ? data.serverName.value : this.serverName,
      libraryKey: data.libraryKey.present ? data.libraryKey.value : this.libraryKey,
      title: data.title.present ? data.title.value : this.title,
      type: data.type.present ? data.type.value : this.type,
      totalCount: data.totalCount.present ? data.totalCount.value : this.totalCount,
      indexedCount: data.indexedCount.present ? data.indexedCount.value : this.indexedCount,
      buildCursor: data.buildCursor.present ? data.buildCursor.value : this.buildCursor,
      lastFullBuildAt: data.lastFullBuildAt.present ? data.lastFullBuildAt.value : this.lastFullBuildAt,
      lastUpdateAt: data.lastUpdateAt.present ? data.lastUpdateAt.value : this.lastUpdateAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('IndexedLibrary(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('serverName: $serverName, ')
          ..write('libraryKey: $libraryKey, ')
          ..write('title: $title, ')
          ..write('type: $type, ')
          ..write('totalCount: $totalCount, ')
          ..write('indexedCount: $indexedCount, ')
          ..write('buildCursor: $buildCursor, ')
          ..write('lastFullBuildAt: $lastFullBuildAt, ')
          ..write('lastUpdateAt: $lastUpdateAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    serverId,
    serverName,
    libraryKey,
    title,
    type,
    totalCount,
    indexedCount,
    buildCursor,
    lastFullBuildAt,
    lastUpdateAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is IndexedLibrary &&
          other.id == this.id &&
          other.serverId == this.serverId &&
          other.serverName == this.serverName &&
          other.libraryKey == this.libraryKey &&
          other.title == this.title &&
          other.type == this.type &&
          other.totalCount == this.totalCount &&
          other.indexedCount == this.indexedCount &&
          other.buildCursor == this.buildCursor &&
          other.lastFullBuildAt == this.lastFullBuildAt &&
          other.lastUpdateAt == this.lastUpdateAt);
}

class IndexLibrariesCompanion extends UpdateCompanion<IndexedLibrary> {
  final Value<String> id;
  final Value<String> serverId;
  final Value<String> serverName;
  final Value<String> libraryKey;
  final Value<String> title;
  final Value<String> type;
  final Value<int> totalCount;
  final Value<int> indexedCount;
  final Value<int?> buildCursor;
  final Value<int?> lastFullBuildAt;
  final Value<int?> lastUpdateAt;
  final Value<int> rowid;
  const IndexLibrariesCompanion({
    this.id = const Value.absent(),
    this.serverId = const Value.absent(),
    this.serverName = const Value.absent(),
    this.libraryKey = const Value.absent(),
    this.title = const Value.absent(),
    this.type = const Value.absent(),
    this.totalCount = const Value.absent(),
    this.indexedCount = const Value.absent(),
    this.buildCursor = const Value.absent(),
    this.lastFullBuildAt = const Value.absent(),
    this.lastUpdateAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  IndexLibrariesCompanion.insert({
    required String id,
    required String serverId,
    required String serverName,
    required String libraryKey,
    required String title,
    required String type,
    this.totalCount = const Value.absent(),
    this.indexedCount = const Value.absent(),
    this.buildCursor = const Value.absent(),
    this.lastFullBuildAt = const Value.absent(),
    this.lastUpdateAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       serverId = Value(serverId),
       serverName = Value(serverName),
       libraryKey = Value(libraryKey),
       title = Value(title),
       type = Value(type);
  static Insertable<IndexedLibrary> custom({
    Expression<String>? id,
    Expression<String>? serverId,
    Expression<String>? serverName,
    Expression<String>? libraryKey,
    Expression<String>? title,
    Expression<String>? type,
    Expression<int>? totalCount,
    Expression<int>? indexedCount,
    Expression<int>? buildCursor,
    Expression<int>? lastFullBuildAt,
    Expression<int>? lastUpdateAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (serverId != null) 'server_id': serverId,
      if (serverName != null) 'server_name': serverName,
      if (libraryKey != null) 'library_key': libraryKey,
      if (title != null) 'title': title,
      if (type != null) 'type': type,
      if (totalCount != null) 'total_count': totalCount,
      if (indexedCount != null) 'indexed_count': indexedCount,
      if (buildCursor != null) 'build_cursor': buildCursor,
      if (lastFullBuildAt != null) 'last_full_build_at': lastFullBuildAt,
      if (lastUpdateAt != null) 'last_update_at': lastUpdateAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  IndexLibrariesCompanion copyWith({
    Value<String>? id,
    Value<String>? serverId,
    Value<String>? serverName,
    Value<String>? libraryKey,
    Value<String>? title,
    Value<String>? type,
    Value<int>? totalCount,
    Value<int>? indexedCount,
    Value<int?>? buildCursor,
    Value<int?>? lastFullBuildAt,
    Value<int?>? lastUpdateAt,
    Value<int>? rowid,
  }) {
    return IndexLibrariesCompanion(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      libraryKey: libraryKey ?? this.libraryKey,
      title: title ?? this.title,
      type: type ?? this.type,
      totalCount: totalCount ?? this.totalCount,
      indexedCount: indexedCount ?? this.indexedCount,
      buildCursor: buildCursor ?? this.buildCursor,
      lastFullBuildAt: lastFullBuildAt ?? this.lastFullBuildAt,
      lastUpdateAt: lastUpdateAt ?? this.lastUpdateAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (serverName.present) {
      map['server_name'] = Variable<String>(serverName.value);
    }
    if (libraryKey.present) {
      map['library_key'] = Variable<String>(libraryKey.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (totalCount.present) {
      map['total_count'] = Variable<int>(totalCount.value);
    }
    if (indexedCount.present) {
      map['indexed_count'] = Variable<int>(indexedCount.value);
    }
    if (buildCursor.present) {
      map['build_cursor'] = Variable<int>(buildCursor.value);
    }
    if (lastFullBuildAt.present) {
      map['last_full_build_at'] = Variable<int>(lastFullBuildAt.value);
    }
    if (lastUpdateAt.present) {
      map['last_update_at'] = Variable<int>(lastUpdateAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('IndexLibrariesCompanion(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('serverName: $serverName, ')
          ..write('libraryKey: $libraryKey, ')
          ..write('title: $title, ')
          ..write('type: $type, ')
          ..write('totalCount: $totalCount, ')
          ..write('indexedCount: $indexedCount, ')
          ..write('buildCursor: $buildCursor, ')
          ..write('lastFullBuildAt: $lastFullBuildAt, ')
          ..write('lastUpdateAt: $lastUpdateAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$IndexDatabase extends GeneratedDatabase {
  _$IndexDatabase(QueryExecutor e) : super(e);
  $IndexDatabaseManager get managers => $IndexDatabaseManager(this);
  late final $IndexTitlesTable indexTitles = $IndexTitlesTable(this);
  late final $IndexLibrariesTable indexLibraries = $IndexLibrariesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [indexTitles, indexLibraries];
}

typedef $$IndexTitlesTableCreateCompanionBuilder =
    IndexTitlesCompanion Function({
      required String id,
      required String serverId,
      required String serverName,
      required String libraryKey,
      required String libraryTitle,
      required String ratingKey,
      required String type,
      required String title,
      Value<String?> originalTitle,
      Value<int?> year,
      Value<String?> releaseDate,
      Value<int?> addedAt,
      Value<int?> updatedAt,
      Value<int?> durationMinutes,
      Value<String?> contentRating,
      Value<double?> audienceRating,
      Value<double?> criticRating,
      Value<String?> studio,
      Value<String?> summary,
      Value<String?> tagline,
      Value<String> genres,
      Value<String> countries,
      Value<String> directors,
      Value<String> writers,
      Value<String> cast,
      Value<String> collections,
      Value<String?> imdb,
      Value<String?> tmdb,
      Value<String?> tvdb,
      required String groupKey,
      Value<int?> episodeCount,
      Value<int?> watchedEpisodeCount,
      Value<int?> viewCount,
      Value<int?> lastViewedAt,
      Value<int?> viewOffsetMs,
      Value<int> rowid,
    });
typedef $$IndexTitlesTableUpdateCompanionBuilder =
    IndexTitlesCompanion Function({
      Value<String> id,
      Value<String> serverId,
      Value<String> serverName,
      Value<String> libraryKey,
      Value<String> libraryTitle,
      Value<String> ratingKey,
      Value<String> type,
      Value<String> title,
      Value<String?> originalTitle,
      Value<int?> year,
      Value<String?> releaseDate,
      Value<int?> addedAt,
      Value<int?> updatedAt,
      Value<int?> durationMinutes,
      Value<String?> contentRating,
      Value<double?> audienceRating,
      Value<double?> criticRating,
      Value<String?> studio,
      Value<String?> summary,
      Value<String?> tagline,
      Value<String> genres,
      Value<String> countries,
      Value<String> directors,
      Value<String> writers,
      Value<String> cast,
      Value<String> collections,
      Value<String?> imdb,
      Value<String?> tmdb,
      Value<String?> tvdb,
      Value<String> groupKey,
      Value<int?> episodeCount,
      Value<int?> watchedEpisodeCount,
      Value<int?> viewCount,
      Value<int?> lastViewedAt,
      Value<int?> viewOffsetMs,
      Value<int> rowid,
    });

class $$IndexTitlesTableFilterComposer extends Composer<_$IndexDatabase, $IndexTitlesTable> {
  $$IndexTitlesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get serverName =>
      $composableBuilder(column: $table.serverName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get libraryKey =>
      $composableBuilder(column: $table.libraryKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get libraryTitle =>
      $composableBuilder(column: $table.libraryTitle, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get ratingKey =>
      $composableBuilder(column: $table.ratingKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get originalTitle =>
      $composableBuilder(column: $table.originalTitle, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get year => $composableBuilder(column: $table.year, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get releaseDate =>
      $composableBuilder(column: $table.releaseDate, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durationMinutes =>
      $composableBuilder(column: $table.durationMinutes, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get contentRating =>
      $composableBuilder(column: $table.contentRating, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get audienceRating =>
      $composableBuilder(column: $table.audienceRating, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get criticRating =>
      $composableBuilder(column: $table.criticRating, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get studio =>
      $composableBuilder(column: $table.studio, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tagline =>
      $composableBuilder(column: $table.tagline, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get genres =>
      $composableBuilder(column: $table.genres, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get countries =>
      $composableBuilder(column: $table.countries, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get directors =>
      $composableBuilder(column: $table.directors, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get writers =>
      $composableBuilder(column: $table.writers, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get cast => $composableBuilder(column: $table.cast, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get collections =>
      $composableBuilder(column: $table.collections, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get imdb => $composableBuilder(column: $table.imdb, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tmdb => $composableBuilder(column: $table.tmdb, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tvdb => $composableBuilder(column: $table.tvdb, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get groupKey =>
      $composableBuilder(column: $table.groupKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get episodeCount =>
      $composableBuilder(column: $table.episodeCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get watchedEpisodeCount =>
      $composableBuilder(column: $table.watchedEpisodeCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get viewCount =>
      $composableBuilder(column: $table.viewCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastViewedAt =>
      $composableBuilder(column: $table.lastViewedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get viewOffsetMs =>
      $composableBuilder(column: $table.viewOffsetMs, builder: (column) => ColumnFilters(column));
}

class $$IndexTitlesTableOrderingComposer extends Composer<_$IndexDatabase, $IndexTitlesTable> {
  $$IndexTitlesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get serverName =>
      $composableBuilder(column: $table.serverName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get libraryKey =>
      $composableBuilder(column: $table.libraryKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get libraryTitle =>
      $composableBuilder(column: $table.libraryTitle, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get ratingKey =>
      $composableBuilder(column: $table.ratingKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get originalTitle =>
      $composableBuilder(column: $table.originalTitle, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get releaseDate =>
      $composableBuilder(column: $table.releaseDate, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durationMinutes =>
      $composableBuilder(column: $table.durationMinutes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get contentRating =>
      $composableBuilder(column: $table.contentRating, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get audienceRating =>
      $composableBuilder(column: $table.audienceRating, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get criticRating =>
      $composableBuilder(column: $table.criticRating, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get studio =>
      $composableBuilder(column: $table.studio, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tagline =>
      $composableBuilder(column: $table.tagline, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get genres =>
      $composableBuilder(column: $table.genres, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get countries =>
      $composableBuilder(column: $table.countries, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get directors =>
      $composableBuilder(column: $table.directors, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get writers =>
      $composableBuilder(column: $table.writers, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get cast =>
      $composableBuilder(column: $table.cast, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get collections =>
      $composableBuilder(column: $table.collections, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get imdb =>
      $composableBuilder(column: $table.imdb, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tmdb =>
      $composableBuilder(column: $table.tmdb, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tvdb =>
      $composableBuilder(column: $table.tvdb, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get groupKey =>
      $composableBuilder(column: $table.groupKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get episodeCount =>
      $composableBuilder(column: $table.episodeCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get watchedEpisodeCount =>
      $composableBuilder(column: $table.watchedEpisodeCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get viewCount =>
      $composableBuilder(column: $table.viewCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastViewedAt =>
      $composableBuilder(column: $table.lastViewedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get viewOffsetMs =>
      $composableBuilder(column: $table.viewOffsetMs, builder: (column) => ColumnOrderings(column));
}

class $$IndexTitlesTableAnnotationComposer extends Composer<_$IndexDatabase, $IndexTitlesTable> {
  $$IndexTitlesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id => $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get serverId => $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get serverName => $composableBuilder(column: $table.serverName, builder: (column) => column);

  GeneratedColumn<String> get libraryKey => $composableBuilder(column: $table.libraryKey, builder: (column) => column);

  GeneratedColumn<String> get libraryTitle =>
      $composableBuilder(column: $table.libraryTitle, builder: (column) => column);

  GeneratedColumn<String> get ratingKey => $composableBuilder(column: $table.ratingKey, builder: (column) => column);

  GeneratedColumn<String> get type => $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get title => $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get originalTitle =>
      $composableBuilder(column: $table.originalTitle, builder: (column) => column);

  GeneratedColumn<int> get year => $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<String> get releaseDate =>
      $composableBuilder(column: $table.releaseDate, builder: (column) => column);

  GeneratedColumn<int> get addedAt => $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt => $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get durationMinutes =>
      $composableBuilder(column: $table.durationMinutes, builder: (column) => column);

  GeneratedColumn<String> get contentRating =>
      $composableBuilder(column: $table.contentRating, builder: (column) => column);

  GeneratedColumn<double> get audienceRating =>
      $composableBuilder(column: $table.audienceRating, builder: (column) => column);

  GeneratedColumn<double> get criticRating =>
      $composableBuilder(column: $table.criticRating, builder: (column) => column);

  GeneratedColumn<String> get studio => $composableBuilder(column: $table.studio, builder: (column) => column);

  GeneratedColumn<String> get summary => $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<String> get tagline => $composableBuilder(column: $table.tagline, builder: (column) => column);

  GeneratedColumn<String> get genres => $composableBuilder(column: $table.genres, builder: (column) => column);

  GeneratedColumn<String> get countries => $composableBuilder(column: $table.countries, builder: (column) => column);

  GeneratedColumn<String> get directors => $composableBuilder(column: $table.directors, builder: (column) => column);

  GeneratedColumn<String> get writers => $composableBuilder(column: $table.writers, builder: (column) => column);

  GeneratedColumn<String> get cast => $composableBuilder(column: $table.cast, builder: (column) => column);

  GeneratedColumn<String> get collections =>
      $composableBuilder(column: $table.collections, builder: (column) => column);

  GeneratedColumn<String> get imdb => $composableBuilder(column: $table.imdb, builder: (column) => column);

  GeneratedColumn<String> get tmdb => $composableBuilder(column: $table.tmdb, builder: (column) => column);

  GeneratedColumn<String> get tvdb => $composableBuilder(column: $table.tvdb, builder: (column) => column);

  GeneratedColumn<String> get groupKey => $composableBuilder(column: $table.groupKey, builder: (column) => column);

  GeneratedColumn<int> get episodeCount => $composableBuilder(column: $table.episodeCount, builder: (column) => column);

  GeneratedColumn<int> get watchedEpisodeCount =>
      $composableBuilder(column: $table.watchedEpisodeCount, builder: (column) => column);

  GeneratedColumn<int> get viewCount => $composableBuilder(column: $table.viewCount, builder: (column) => column);

  GeneratedColumn<int> get lastViewedAt => $composableBuilder(column: $table.lastViewedAt, builder: (column) => column);

  GeneratedColumn<int> get viewOffsetMs => $composableBuilder(column: $table.viewOffsetMs, builder: (column) => column);
}

class $$IndexTitlesTableTableManager
    extends
        RootTableManager<
          _$IndexDatabase,
          $IndexTitlesTable,
          IndexedTitle,
          $$IndexTitlesTableFilterComposer,
          $$IndexTitlesTableOrderingComposer,
          $$IndexTitlesTableAnnotationComposer,
          $$IndexTitlesTableCreateCompanionBuilder,
          $$IndexTitlesTableUpdateCompanionBuilder,
          (IndexedTitle, BaseReferences<_$IndexDatabase, $IndexTitlesTable, IndexedTitle>),
          IndexedTitle,
          PrefetchHooks Function()
        > {
  $$IndexTitlesTableTableManager(_$IndexDatabase db, $IndexTitlesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$IndexTitlesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$IndexTitlesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$IndexTitlesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> serverId = const Value.absent(),
                Value<String> serverName = const Value.absent(),
                Value<String> libraryKey = const Value.absent(),
                Value<String> libraryTitle = const Value.absent(),
                Value<String> ratingKey = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> originalTitle = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> releaseDate = const Value.absent(),
                Value<int?> addedAt = const Value.absent(),
                Value<int?> updatedAt = const Value.absent(),
                Value<int?> durationMinutes = const Value.absent(),
                Value<String?> contentRating = const Value.absent(),
                Value<double?> audienceRating = const Value.absent(),
                Value<double?> criticRating = const Value.absent(),
                Value<String?> studio = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<String?> tagline = const Value.absent(),
                Value<String> genres = const Value.absent(),
                Value<String> countries = const Value.absent(),
                Value<String> directors = const Value.absent(),
                Value<String> writers = const Value.absent(),
                Value<String> cast = const Value.absent(),
                Value<String> collections = const Value.absent(),
                Value<String?> imdb = const Value.absent(),
                Value<String?> tmdb = const Value.absent(),
                Value<String?> tvdb = const Value.absent(),
                Value<String> groupKey = const Value.absent(),
                Value<int?> episodeCount = const Value.absent(),
                Value<int?> watchedEpisodeCount = const Value.absent(),
                Value<int?> viewCount = const Value.absent(),
                Value<int?> lastViewedAt = const Value.absent(),
                Value<int?> viewOffsetMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IndexTitlesCompanion(
                id: id,
                serverId: serverId,
                serverName: serverName,
                libraryKey: libraryKey,
                libraryTitle: libraryTitle,
                ratingKey: ratingKey,
                type: type,
                title: title,
                originalTitle: originalTitle,
                year: year,
                releaseDate: releaseDate,
                addedAt: addedAt,
                updatedAt: updatedAt,
                durationMinutes: durationMinutes,
                contentRating: contentRating,
                audienceRating: audienceRating,
                criticRating: criticRating,
                studio: studio,
                summary: summary,
                tagline: tagline,
                genres: genres,
                countries: countries,
                directors: directors,
                writers: writers,
                cast: cast,
                collections: collections,
                imdb: imdb,
                tmdb: tmdb,
                tvdb: tvdb,
                groupKey: groupKey,
                episodeCount: episodeCount,
                watchedEpisodeCount: watchedEpisodeCount,
                viewCount: viewCount,
                lastViewedAt: lastViewedAt,
                viewOffsetMs: viewOffsetMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String serverId,
                required String serverName,
                required String libraryKey,
                required String libraryTitle,
                required String ratingKey,
                required String type,
                required String title,
                Value<String?> originalTitle = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> releaseDate = const Value.absent(),
                Value<int?> addedAt = const Value.absent(),
                Value<int?> updatedAt = const Value.absent(),
                Value<int?> durationMinutes = const Value.absent(),
                Value<String?> contentRating = const Value.absent(),
                Value<double?> audienceRating = const Value.absent(),
                Value<double?> criticRating = const Value.absent(),
                Value<String?> studio = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<String?> tagline = const Value.absent(),
                Value<String> genres = const Value.absent(),
                Value<String> countries = const Value.absent(),
                Value<String> directors = const Value.absent(),
                Value<String> writers = const Value.absent(),
                Value<String> cast = const Value.absent(),
                Value<String> collections = const Value.absent(),
                Value<String?> imdb = const Value.absent(),
                Value<String?> tmdb = const Value.absent(),
                Value<String?> tvdb = const Value.absent(),
                required String groupKey,
                Value<int?> episodeCount = const Value.absent(),
                Value<int?> watchedEpisodeCount = const Value.absent(),
                Value<int?> viewCount = const Value.absent(),
                Value<int?> lastViewedAt = const Value.absent(),
                Value<int?> viewOffsetMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IndexTitlesCompanion.insert(
                id: id,
                serverId: serverId,
                serverName: serverName,
                libraryKey: libraryKey,
                libraryTitle: libraryTitle,
                ratingKey: ratingKey,
                type: type,
                title: title,
                originalTitle: originalTitle,
                year: year,
                releaseDate: releaseDate,
                addedAt: addedAt,
                updatedAt: updatedAt,
                durationMinutes: durationMinutes,
                contentRating: contentRating,
                audienceRating: audienceRating,
                criticRating: criticRating,
                studio: studio,
                summary: summary,
                tagline: tagline,
                genres: genres,
                countries: countries,
                directors: directors,
                writers: writers,
                cast: cast,
                collections: collections,
                imdb: imdb,
                tmdb: tmdb,
                tvdb: tvdb,
                groupKey: groupKey,
                episodeCount: episodeCount,
                watchedEpisodeCount: watchedEpisodeCount,
                viewCount: viewCount,
                lastViewedAt: lastViewedAt,
                viewOffsetMs: viewOffsetMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0.map((e) => (e.readTable(table), BaseReferences(db, table, e))).toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$IndexTitlesTableProcessedTableManager =
    ProcessedTableManager<
      _$IndexDatabase,
      $IndexTitlesTable,
      IndexedTitle,
      $$IndexTitlesTableFilterComposer,
      $$IndexTitlesTableOrderingComposer,
      $$IndexTitlesTableAnnotationComposer,
      $$IndexTitlesTableCreateCompanionBuilder,
      $$IndexTitlesTableUpdateCompanionBuilder,
      (IndexedTitle, BaseReferences<_$IndexDatabase, $IndexTitlesTable, IndexedTitle>),
      IndexedTitle,
      PrefetchHooks Function()
    >;
typedef $$IndexLibrariesTableCreateCompanionBuilder =
    IndexLibrariesCompanion Function({
      required String id,
      required String serverId,
      required String serverName,
      required String libraryKey,
      required String title,
      required String type,
      Value<int> totalCount,
      Value<int> indexedCount,
      Value<int?> buildCursor,
      Value<int?> lastFullBuildAt,
      Value<int?> lastUpdateAt,
      Value<int> rowid,
    });
typedef $$IndexLibrariesTableUpdateCompanionBuilder =
    IndexLibrariesCompanion Function({
      Value<String> id,
      Value<String> serverId,
      Value<String> serverName,
      Value<String> libraryKey,
      Value<String> title,
      Value<String> type,
      Value<int> totalCount,
      Value<int> indexedCount,
      Value<int?> buildCursor,
      Value<int?> lastFullBuildAt,
      Value<int?> lastUpdateAt,
      Value<int> rowid,
    });

class $$IndexLibrariesTableFilterComposer extends Composer<_$IndexDatabase, $IndexLibrariesTable> {
  $$IndexLibrariesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get serverName =>
      $composableBuilder(column: $table.serverName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get libraryKey =>
      $composableBuilder(column: $table.libraryKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get totalCount =>
      $composableBuilder(column: $table.totalCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get indexedCount =>
      $composableBuilder(column: $table.indexedCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get buildCursor =>
      $composableBuilder(column: $table.buildCursor, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastFullBuildAt =>
      $composableBuilder(column: $table.lastFullBuildAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastUpdateAt =>
      $composableBuilder(column: $table.lastUpdateAt, builder: (column) => ColumnFilters(column));
}

class $$IndexLibrariesTableOrderingComposer extends Composer<_$IndexDatabase, $IndexLibrariesTable> {
  $$IndexLibrariesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get serverName =>
      $composableBuilder(column: $table.serverName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get libraryKey =>
      $composableBuilder(column: $table.libraryKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get totalCount =>
      $composableBuilder(column: $table.totalCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get indexedCount =>
      $composableBuilder(column: $table.indexedCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get buildCursor =>
      $composableBuilder(column: $table.buildCursor, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastFullBuildAt =>
      $composableBuilder(column: $table.lastFullBuildAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastUpdateAt =>
      $composableBuilder(column: $table.lastUpdateAt, builder: (column) => ColumnOrderings(column));
}

class $$IndexLibrariesTableAnnotationComposer extends Composer<_$IndexDatabase, $IndexLibrariesTable> {
  $$IndexLibrariesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id => $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get serverId => $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get serverName => $composableBuilder(column: $table.serverName, builder: (column) => column);

  GeneratedColumn<String> get libraryKey => $composableBuilder(column: $table.libraryKey, builder: (column) => column);

  GeneratedColumn<String> get title => $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get type => $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<int> get totalCount => $composableBuilder(column: $table.totalCount, builder: (column) => column);

  GeneratedColumn<int> get indexedCount => $composableBuilder(column: $table.indexedCount, builder: (column) => column);

  GeneratedColumn<int> get buildCursor => $composableBuilder(column: $table.buildCursor, builder: (column) => column);

  GeneratedColumn<int> get lastFullBuildAt =>
      $composableBuilder(column: $table.lastFullBuildAt, builder: (column) => column);

  GeneratedColumn<int> get lastUpdateAt => $composableBuilder(column: $table.lastUpdateAt, builder: (column) => column);
}

class $$IndexLibrariesTableTableManager
    extends
        RootTableManager<
          _$IndexDatabase,
          $IndexLibrariesTable,
          IndexedLibrary,
          $$IndexLibrariesTableFilterComposer,
          $$IndexLibrariesTableOrderingComposer,
          $$IndexLibrariesTableAnnotationComposer,
          $$IndexLibrariesTableCreateCompanionBuilder,
          $$IndexLibrariesTableUpdateCompanionBuilder,
          (IndexedLibrary, BaseReferences<_$IndexDatabase, $IndexLibrariesTable, IndexedLibrary>),
          IndexedLibrary,
          PrefetchHooks Function()
        > {
  $$IndexLibrariesTableTableManager(_$IndexDatabase db, $IndexLibrariesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$IndexLibrariesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$IndexLibrariesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$IndexLibrariesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> serverId = const Value.absent(),
                Value<String> serverName = const Value.absent(),
                Value<String> libraryKey = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<int> totalCount = const Value.absent(),
                Value<int> indexedCount = const Value.absent(),
                Value<int?> buildCursor = const Value.absent(),
                Value<int?> lastFullBuildAt = const Value.absent(),
                Value<int?> lastUpdateAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IndexLibrariesCompanion(
                id: id,
                serverId: serverId,
                serverName: serverName,
                libraryKey: libraryKey,
                title: title,
                type: type,
                totalCount: totalCount,
                indexedCount: indexedCount,
                buildCursor: buildCursor,
                lastFullBuildAt: lastFullBuildAt,
                lastUpdateAt: lastUpdateAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String serverId,
                required String serverName,
                required String libraryKey,
                required String title,
                required String type,
                Value<int> totalCount = const Value.absent(),
                Value<int> indexedCount = const Value.absent(),
                Value<int?> buildCursor = const Value.absent(),
                Value<int?> lastFullBuildAt = const Value.absent(),
                Value<int?> lastUpdateAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IndexLibrariesCompanion.insert(
                id: id,
                serverId: serverId,
                serverName: serverName,
                libraryKey: libraryKey,
                title: title,
                type: type,
                totalCount: totalCount,
                indexedCount: indexedCount,
                buildCursor: buildCursor,
                lastFullBuildAt: lastFullBuildAt,
                lastUpdateAt: lastUpdateAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0.map((e) => (e.readTable(table), BaseReferences(db, table, e))).toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$IndexLibrariesTableProcessedTableManager =
    ProcessedTableManager<
      _$IndexDatabase,
      $IndexLibrariesTable,
      IndexedLibrary,
      $$IndexLibrariesTableFilterComposer,
      $$IndexLibrariesTableOrderingComposer,
      $$IndexLibrariesTableAnnotationComposer,
      $$IndexLibrariesTableCreateCompanionBuilder,
      $$IndexLibrariesTableUpdateCompanionBuilder,
      (IndexedLibrary, BaseReferences<_$IndexDatabase, $IndexLibrariesTable, IndexedLibrary>),
      IndexedLibrary,
      PrefetchHooks Function()
    >;

class $IndexDatabaseManager {
  final _$IndexDatabase _db;
  $IndexDatabaseManager(this._db);
  $$IndexTitlesTableTableManager get indexTitles => $$IndexTitlesTableTableManager(_db, _db.indexTitles);
  $$IndexLibrariesTableTableManager get indexLibraries => $$IndexLibrariesTableTableManager(_db, _db.indexLibraries);
}
