// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'fork_database.dart';

// ignore_for_file: type=lint
class $HomeRowsTable extends HomeRows
    with TableInfo<$HomeRowsTable, HomeRowRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HomeRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _rowIdMeta = const VerificationMeta('rowId');
  @override
  late final GeneratedColumn<String> rowId = GeneratedColumn<String>(
    'row_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
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
  static const VerificationMeta _sourcesJsonMeta = const VerificationMeta(
    'sourcesJson',
  );
  @override
  late final GeneratedColumn<String> sourcesJson = GeneratedColumn<String>(
    'sources_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  @override
  List<GeneratedColumn> get $columns => [rowId, position, title, sourcesJson];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'home_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<HomeRowRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('row_id')) {
      context.handle(
        _rowIdMeta,
        rowId.isAcceptableOrUnknown(data['row_id']!, _rowIdMeta),
      );
    } else if (isInserting) {
      context.missing(_rowIdMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('sources_json')) {
      context.handle(
        _sourcesJsonMeta,
        sourcesJson.isAcceptableOrUnknown(
          data['sources_json']!,
          _sourcesJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {rowId};
  @override
  HomeRowRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HomeRowRecord(
      rowId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}row_id'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      sourcesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sources_json'],
      )!,
    );
  }

  @override
  $HomeRowsTable createAlias(String alias) {
    return $HomeRowsTable(attachedDatabase, alias);
  }
}

class HomeRowRecord extends DataClass implements Insertable<HomeRowRecord> {
  /// Home row id (see `HomeRowIds`).
  final String rowId;
  final int position;
  final String title;

  /// JSON array of `serverId|hub key` for Plex rows; `[]` otherwise.
  final String sourcesJson;
  const HomeRowRecord({
    required this.rowId,
    required this.position,
    required this.title,
    required this.sourcesJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['row_id'] = Variable<String>(rowId);
    map['position'] = Variable<int>(position);
    map['title'] = Variable<String>(title);
    map['sources_json'] = Variable<String>(sourcesJson);
    return map;
  }

  HomeRowsCompanion toCompanion(bool nullToAbsent) {
    return HomeRowsCompanion(
      rowId: Value(rowId),
      position: Value(position),
      title: Value(title),
      sourcesJson: Value(sourcesJson),
    );
  }

  factory HomeRowRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HomeRowRecord(
      rowId: serializer.fromJson<String>(json['rowId']),
      position: serializer.fromJson<int>(json['position']),
      title: serializer.fromJson<String>(json['title']),
      sourcesJson: serializer.fromJson<String>(json['sourcesJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'rowId': serializer.toJson<String>(rowId),
      'position': serializer.toJson<int>(position),
      'title': serializer.toJson<String>(title),
      'sourcesJson': serializer.toJson<String>(sourcesJson),
    };
  }

  HomeRowRecord copyWith({
    String? rowId,
    int? position,
    String? title,
    String? sourcesJson,
  }) => HomeRowRecord(
    rowId: rowId ?? this.rowId,
    position: position ?? this.position,
    title: title ?? this.title,
    sourcesJson: sourcesJson ?? this.sourcesJson,
  );
  HomeRowRecord copyWithCompanion(HomeRowsCompanion data) {
    return HomeRowRecord(
      rowId: data.rowId.present ? data.rowId.value : this.rowId,
      position: data.position.present ? data.position.value : this.position,
      title: data.title.present ? data.title.value : this.title,
      sourcesJson: data.sourcesJson.present
          ? data.sourcesJson.value
          : this.sourcesJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HomeRowRecord(')
          ..write('rowId: $rowId, ')
          ..write('position: $position, ')
          ..write('title: $title, ')
          ..write('sourcesJson: $sourcesJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(rowId, position, title, sourcesJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HomeRowRecord &&
          other.rowId == this.rowId &&
          other.position == this.position &&
          other.title == this.title &&
          other.sourcesJson == this.sourcesJson);
}

class HomeRowsCompanion extends UpdateCompanion<HomeRowRecord> {
  final Value<String> rowId;
  final Value<int> position;
  final Value<String> title;
  final Value<String> sourcesJson;
  final Value<int> rowid;
  const HomeRowsCompanion({
    this.rowId = const Value.absent(),
    this.position = const Value.absent(),
    this.title = const Value.absent(),
    this.sourcesJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HomeRowsCompanion.insert({
    required String rowId,
    required int position,
    required String title,
    this.sourcesJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : rowId = Value(rowId),
       position = Value(position),
       title = Value(title);
  static Insertable<HomeRowRecord> custom({
    Expression<String>? rowId,
    Expression<int>? position,
    Expression<String>? title,
    Expression<String>? sourcesJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (rowId != null) 'row_id': rowId,
      if (position != null) 'position': position,
      if (title != null) 'title': title,
      if (sourcesJson != null) 'sources_json': sourcesJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HomeRowsCompanion copyWith({
    Value<String>? rowId,
    Value<int>? position,
    Value<String>? title,
    Value<String>? sourcesJson,
    Value<int>? rowid,
  }) {
    return HomeRowsCompanion(
      rowId: rowId ?? this.rowId,
      position: position ?? this.position,
      title: title ?? this.title,
      sourcesJson: sourcesJson ?? this.sourcesJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (rowId.present) {
      map['row_id'] = Variable<String>(rowId.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (sourcesJson.present) {
      map['sources_json'] = Variable<String>(sourcesJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HomeRowsCompanion(')
          ..write('rowId: $rowId, ')
          ..write('position: $position, ')
          ..write('title: $title, ')
          ..write('sourcesJson: $sourcesJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ComfortPausedShowsTable extends ComfortPausedShows
    with TableInfo<$ComfortPausedShowsTable, ComfortPausedRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ComfortPausedShowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _traktIdMeta = const VerificationMeta(
    'traktId',
  );
  @override
  late final GeneratedColumn<int> traktId = GeneratedColumn<int>(
    'trakt_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [traktId, title];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'comfort_paused_shows';
  @override
  VerificationContext validateIntegrity(
    Insertable<ComfortPausedRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('trakt_id')) {
      context.handle(
        _traktIdMeta,
        traktId.isAcceptableOrUnknown(data['trakt_id']!, _traktIdMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {traktId};
  @override
  ComfortPausedRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ComfortPausedRecord(
      traktId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}trakt_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
    );
  }

  @override
  $ComfortPausedShowsTable createAlias(String alias) {
    return $ComfortPausedShowsTable(attachedDatabase, alias);
  }
}

class ComfortPausedRecord extends DataClass
    implements Insertable<ComfortPausedRecord> {
  final int traktId;
  final String title;
  const ComfortPausedRecord({required this.traktId, required this.title});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['trakt_id'] = Variable<int>(traktId);
    map['title'] = Variable<String>(title);
    return map;
  }

  ComfortPausedShowsCompanion toCompanion(bool nullToAbsent) {
    return ComfortPausedShowsCompanion(
      traktId: Value(traktId),
      title: Value(title),
    );
  }

  factory ComfortPausedRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ComfortPausedRecord(
      traktId: serializer.fromJson<int>(json['traktId']),
      title: serializer.fromJson<String>(json['title']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'traktId': serializer.toJson<int>(traktId),
      'title': serializer.toJson<String>(title),
    };
  }

  ComfortPausedRecord copyWith({int? traktId, String? title}) =>
      ComfortPausedRecord(
        traktId: traktId ?? this.traktId,
        title: title ?? this.title,
      );
  ComfortPausedRecord copyWithCompanion(ComfortPausedShowsCompanion data) {
    return ComfortPausedRecord(
      traktId: data.traktId.present ? data.traktId.value : this.traktId,
      title: data.title.present ? data.title.value : this.title,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ComfortPausedRecord(')
          ..write('traktId: $traktId, ')
          ..write('title: $title')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(traktId, title);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ComfortPausedRecord &&
          other.traktId == this.traktId &&
          other.title == this.title);
}

class ComfortPausedShowsCompanion extends UpdateCompanion<ComfortPausedRecord> {
  final Value<int> traktId;
  final Value<String> title;
  const ComfortPausedShowsCompanion({
    this.traktId = const Value.absent(),
    this.title = const Value.absent(),
  });
  ComfortPausedShowsCompanion.insert({
    this.traktId = const Value.absent(),
    this.title = const Value.absent(),
  });
  static Insertable<ComfortPausedRecord> custom({
    Expression<int>? traktId,
    Expression<String>? title,
  }) {
    return RawValuesInsertable({
      if (traktId != null) 'trakt_id': traktId,
      if (title != null) 'title': title,
    });
  }

  ComfortPausedShowsCompanion copyWith({
    Value<int>? traktId,
    Value<String>? title,
  }) {
    return ComfortPausedShowsCompanion(
      traktId: traktId ?? this.traktId,
      title: title ?? this.title,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (traktId.present) {
      map['trakt_id'] = Variable<int>(traktId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ComfortPausedShowsCompanion(')
          ..write('traktId: $traktId, ')
          ..write('title: $title')
          ..write(')'))
        .toString();
  }
}

class $ShortlistItemsTable extends ShortlistItems
    with TableInfo<$ShortlistItemsTable, ShortlistRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ShortlistItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _itemKeyMeta = const VerificationMeta(
    'itemKey',
  );
  @override
  late final GeneratedColumn<String> itemKey = GeneratedColumn<String>(
    'item_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
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
  static const VerificationMeta _itemJsonMeta = const VerificationMeta(
    'itemJson',
  );
  @override
  late final GeneratedColumn<String> itemJson = GeneratedColumn<String>(
    'item_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    itemKey,
    position,
    title,
    itemJson,
    addedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'shortlist_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<ShortlistRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('item_key')) {
      context.handle(
        _itemKeyMeta,
        itemKey.isAcceptableOrUnknown(data['item_key']!, _itemKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_itemKeyMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('item_json')) {
      context.handle(
        _itemJsonMeta,
        itemJson.isAcceptableOrUnknown(data['item_json']!, _itemJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_itemJsonMeta);
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {itemKey};
  @override
  ShortlistRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ShortlistRecord(
      itemKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}item_key'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      itemJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}item_json'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}added_at'],
      )!,
    );
  }

  @override
  $ShortlistItemsTable createAlias(String alias) {
    return $ShortlistItemsTable(attachedDatabase, alias);
  }
}

class ShortlistRecord extends DataClass implements Insertable<ShortlistRecord> {
  final String itemKey;
  final int position;
  final String title;
  final String itemJson;
  final int addedAt;
  const ShortlistRecord({
    required this.itemKey,
    required this.position,
    required this.title,
    required this.itemJson,
    required this.addedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['item_key'] = Variable<String>(itemKey);
    map['position'] = Variable<int>(position);
    map['title'] = Variable<String>(title);
    map['item_json'] = Variable<String>(itemJson);
    map['added_at'] = Variable<int>(addedAt);
    return map;
  }

  ShortlistItemsCompanion toCompanion(bool nullToAbsent) {
    return ShortlistItemsCompanion(
      itemKey: Value(itemKey),
      position: Value(position),
      title: Value(title),
      itemJson: Value(itemJson),
      addedAt: Value(addedAt),
    );
  }

  factory ShortlistRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ShortlistRecord(
      itemKey: serializer.fromJson<String>(json['itemKey']),
      position: serializer.fromJson<int>(json['position']),
      title: serializer.fromJson<String>(json['title']),
      itemJson: serializer.fromJson<String>(json['itemJson']),
      addedAt: serializer.fromJson<int>(json['addedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'itemKey': serializer.toJson<String>(itemKey),
      'position': serializer.toJson<int>(position),
      'title': serializer.toJson<String>(title),
      'itemJson': serializer.toJson<String>(itemJson),
      'addedAt': serializer.toJson<int>(addedAt),
    };
  }

  ShortlistRecord copyWith({
    String? itemKey,
    int? position,
    String? title,
    String? itemJson,
    int? addedAt,
  }) => ShortlistRecord(
    itemKey: itemKey ?? this.itemKey,
    position: position ?? this.position,
    title: title ?? this.title,
    itemJson: itemJson ?? this.itemJson,
    addedAt: addedAt ?? this.addedAt,
  );
  ShortlistRecord copyWithCompanion(ShortlistItemsCompanion data) {
    return ShortlistRecord(
      itemKey: data.itemKey.present ? data.itemKey.value : this.itemKey,
      position: data.position.present ? data.position.value : this.position,
      title: data.title.present ? data.title.value : this.title,
      itemJson: data.itemJson.present ? data.itemJson.value : this.itemJson,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ShortlistRecord(')
          ..write('itemKey: $itemKey, ')
          ..write('position: $position, ')
          ..write('title: $title, ')
          ..write('itemJson: $itemJson, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(itemKey, position, title, itemJson, addedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ShortlistRecord &&
          other.itemKey == this.itemKey &&
          other.position == this.position &&
          other.title == this.title &&
          other.itemJson == this.itemJson &&
          other.addedAt == this.addedAt);
}

class ShortlistItemsCompanion extends UpdateCompanion<ShortlistRecord> {
  final Value<String> itemKey;
  final Value<int> position;
  final Value<String> title;
  final Value<String> itemJson;
  final Value<int> addedAt;
  final Value<int> rowid;
  const ShortlistItemsCompanion({
    this.itemKey = const Value.absent(),
    this.position = const Value.absent(),
    this.title = const Value.absent(),
    this.itemJson = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ShortlistItemsCompanion.insert({
    required String itemKey,
    required int position,
    required String title,
    required String itemJson,
    required int addedAt,
    this.rowid = const Value.absent(),
  }) : itemKey = Value(itemKey),
       position = Value(position),
       title = Value(title),
       itemJson = Value(itemJson),
       addedAt = Value(addedAt);
  static Insertable<ShortlistRecord> custom({
    Expression<String>? itemKey,
    Expression<int>? position,
    Expression<String>? title,
    Expression<String>? itemJson,
    Expression<int>? addedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (itemKey != null) 'item_key': itemKey,
      if (position != null) 'position': position,
      if (title != null) 'title': title,
      if (itemJson != null) 'item_json': itemJson,
      if (addedAt != null) 'added_at': addedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ShortlistItemsCompanion copyWith({
    Value<String>? itemKey,
    Value<int>? position,
    Value<String>? title,
    Value<String>? itemJson,
    Value<int>? addedAt,
    Value<int>? rowid,
  }) {
    return ShortlistItemsCompanion(
      itemKey: itemKey ?? this.itemKey,
      position: position ?? this.position,
      title: title ?? this.title,
      itemJson: itemJson ?? this.itemJson,
      addedAt: addedAt ?? this.addedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (itemKey.present) {
      map['item_key'] = Variable<String>(itemKey.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (itemJson.present) {
      map['item_json'] = Variable<String>(itemJson.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<int>(addedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ShortlistItemsCompanion(')
          ..write('itemKey: $itemKey, ')
          ..write('position: $position, ')
          ..write('title: $title, ')
          ..write('itemJson: $itemJson, ')
          ..write('addedAt: $addedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ForkSettingsTable extends ForkSettings
    with TableInfo<$ForkSettingsTable, ForkSettingRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ForkSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'fork_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<ForkSettingRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  ForkSettingRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ForkSettingRecord(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $ForkSettingsTable createAlias(String alias) {
    return $ForkSettingsTable(attachedDatabase, alias);
  }
}

class ForkSettingRecord extends DataClass
    implements Insertable<ForkSettingRecord> {
  final String key;
  final String value;
  const ForkSettingRecord({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  ForkSettingsCompanion toCompanion(bool nullToAbsent) {
    return ForkSettingsCompanion(key: Value(key), value: Value(value));
  }

  factory ForkSettingRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ForkSettingRecord(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  ForkSettingRecord copyWith({String? key, String? value}) =>
      ForkSettingRecord(key: key ?? this.key, value: value ?? this.value);
  ForkSettingRecord copyWithCompanion(ForkSettingsCompanion data) {
    return ForkSettingRecord(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ForkSettingRecord(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ForkSettingRecord &&
          other.key == this.key &&
          other.value == this.value);
}

class ForkSettingsCompanion extends UpdateCompanion<ForkSettingRecord> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const ForkSettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ForkSettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<ForkSettingRecord> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ForkSettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return ForkSettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ForkSettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncStampsTable extends SyncStamps
    with TableInfo<$SyncStampsTable, SyncStampRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncStampsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _unitMeta = const VerificationMeta('unit');
  @override
  late final GeneratedColumn<String> unit = GeneratedColumn<String>(
    'unit',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stampMeta = const VerificationMeta('stamp');
  @override
  late final GeneratedColumn<int> stamp = GeneratedColumn<int>(
    'stamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [unit, stamp, deleted];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_stamps';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncStampRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('unit')) {
      context.handle(
        _unitMeta,
        unit.isAcceptableOrUnknown(data['unit']!, _unitMeta),
      );
    } else if (isInserting) {
      context.missing(_unitMeta);
    }
    if (data.containsKey('stamp')) {
      context.handle(
        _stampMeta,
        stamp.isAcceptableOrUnknown(data['stamp']!, _stampMeta),
      );
    } else if (isInserting) {
      context.missing(_stampMeta);
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {unit};
  @override
  SyncStampRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncStampRecord(
      unit: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}unit'],
      )!,
      stamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}stamp'],
      )!,
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
    );
  }

  @override
  $SyncStampsTable createAlias(String alias) {
    return $SyncStampsTable(attachedDatabase, alias);
  }
}

class SyncStampRecord extends DataClass implements Insertable<SyncStampRecord> {
  final String unit;
  final int stamp;
  final bool deleted;
  const SyncStampRecord({
    required this.unit,
    required this.stamp,
    required this.deleted,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['unit'] = Variable<String>(unit);
    map['stamp'] = Variable<int>(stamp);
    map['deleted'] = Variable<bool>(deleted);
    return map;
  }

  SyncStampsCompanion toCompanion(bool nullToAbsent) {
    return SyncStampsCompanion(
      unit: Value(unit),
      stamp: Value(stamp),
      deleted: Value(deleted),
    );
  }

  factory SyncStampRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncStampRecord(
      unit: serializer.fromJson<String>(json['unit']),
      stamp: serializer.fromJson<int>(json['stamp']),
      deleted: serializer.fromJson<bool>(json['deleted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'unit': serializer.toJson<String>(unit),
      'stamp': serializer.toJson<int>(stamp),
      'deleted': serializer.toJson<bool>(deleted),
    };
  }

  SyncStampRecord copyWith({String? unit, int? stamp, bool? deleted}) =>
      SyncStampRecord(
        unit: unit ?? this.unit,
        stamp: stamp ?? this.stamp,
        deleted: deleted ?? this.deleted,
      );
  SyncStampRecord copyWithCompanion(SyncStampsCompanion data) {
    return SyncStampRecord(
      unit: data.unit.present ? data.unit.value : this.unit,
      stamp: data.stamp.present ? data.stamp.value : this.stamp,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncStampRecord(')
          ..write('unit: $unit, ')
          ..write('stamp: $stamp, ')
          ..write('deleted: $deleted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(unit, stamp, deleted);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncStampRecord &&
          other.unit == this.unit &&
          other.stamp == this.stamp &&
          other.deleted == this.deleted);
}

class SyncStampsCompanion extends UpdateCompanion<SyncStampRecord> {
  final Value<String> unit;
  final Value<int> stamp;
  final Value<bool> deleted;
  final Value<int> rowid;
  const SyncStampsCompanion({
    this.unit = const Value.absent(),
    this.stamp = const Value.absent(),
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncStampsCompanion.insert({
    required String unit,
    required int stamp,
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : unit = Value(unit),
       stamp = Value(stamp);
  static Insertable<SyncStampRecord> custom({
    Expression<String>? unit,
    Expression<int>? stamp,
    Expression<bool>? deleted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (unit != null) 'unit': unit,
      if (stamp != null) 'stamp': stamp,
      if (deleted != null) 'deleted': deleted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncStampsCompanion copyWith({
    Value<String>? unit,
    Value<int>? stamp,
    Value<bool>? deleted,
    Value<int>? rowid,
  }) {
    return SyncStampsCompanion(
      unit: unit ?? this.unit,
      stamp: stamp ?? this.stamp,
      deleted: deleted ?? this.deleted,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (unit.present) {
      map['unit'] = Variable<String>(unit.value);
    }
    if (stamp.present) {
      map['stamp'] = Variable<int>(stamp.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStampsCompanion(')
          ..write('unit: $unit, ')
          ..write('stamp: $stamp, ')
          ..write('deleted: $deleted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$ForkDatabase extends GeneratedDatabase {
  _$ForkDatabase(QueryExecutor e) : super(e);
  $ForkDatabaseManager get managers => $ForkDatabaseManager(this);
  late final $HomeRowsTable homeRows = $HomeRowsTable(this);
  late final $ComfortPausedShowsTable comfortPausedShows =
      $ComfortPausedShowsTable(this);
  late final $ShortlistItemsTable shortlistItems = $ShortlistItemsTable(this);
  late final $ForkSettingsTable forkSettings = $ForkSettingsTable(this);
  late final $SyncStampsTable syncStamps = $SyncStampsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    homeRows,
    comfortPausedShows,
    shortlistItems,
    forkSettings,
    syncStamps,
  ];
}

typedef $$HomeRowsTableCreateCompanionBuilder =
    HomeRowsCompanion Function({
      required String rowId,
      required int position,
      required String title,
      Value<String> sourcesJson,
      Value<int> rowid,
    });
typedef $$HomeRowsTableUpdateCompanionBuilder =
    HomeRowsCompanion Function({
      Value<String> rowId,
      Value<int> position,
      Value<String> title,
      Value<String> sourcesJson,
      Value<int> rowid,
    });

class $$HomeRowsTableFilterComposer
    extends Composer<_$ForkDatabase, $HomeRowsTable> {
  $$HomeRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourcesJson => $composableBuilder(
    column: $table.sourcesJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$HomeRowsTableOrderingComposer
    extends Composer<_$ForkDatabase, $HomeRowsTable> {
  $$HomeRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourcesJson => $composableBuilder(
    column: $table.sourcesJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$HomeRowsTableAnnotationComposer
    extends Composer<_$ForkDatabase, $HomeRowsTable> {
  $$HomeRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get rowId =>
      $composableBuilder(column: $table.rowId, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get sourcesJson => $composableBuilder(
    column: $table.sourcesJson,
    builder: (column) => column,
  );
}

class $$HomeRowsTableTableManager
    extends
        RootTableManager<
          _$ForkDatabase,
          $HomeRowsTable,
          HomeRowRecord,
          $$HomeRowsTableFilterComposer,
          $$HomeRowsTableOrderingComposer,
          $$HomeRowsTableAnnotationComposer,
          $$HomeRowsTableCreateCompanionBuilder,
          $$HomeRowsTableUpdateCompanionBuilder,
          (
            HomeRowRecord,
            BaseReferences<_$ForkDatabase, $HomeRowsTable, HomeRowRecord>,
          ),
          HomeRowRecord,
          PrefetchHooks Function()
        > {
  $$HomeRowsTableTableManager(_$ForkDatabase db, $HomeRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HomeRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HomeRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HomeRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> rowId = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> sourcesJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HomeRowsCompanion(
                rowId: rowId,
                position: position,
                title: title,
                sourcesJson: sourcesJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String rowId,
                required int position,
                required String title,
                Value<String> sourcesJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HomeRowsCompanion.insert(
                rowId: rowId,
                position: position,
                title: title,
                sourcesJson: sourcesJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$HomeRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ForkDatabase,
      $HomeRowsTable,
      HomeRowRecord,
      $$HomeRowsTableFilterComposer,
      $$HomeRowsTableOrderingComposer,
      $$HomeRowsTableAnnotationComposer,
      $$HomeRowsTableCreateCompanionBuilder,
      $$HomeRowsTableUpdateCompanionBuilder,
      (
        HomeRowRecord,
        BaseReferences<_$ForkDatabase, $HomeRowsTable, HomeRowRecord>,
      ),
      HomeRowRecord,
      PrefetchHooks Function()
    >;
typedef $$ComfortPausedShowsTableCreateCompanionBuilder =
    ComfortPausedShowsCompanion Function({
      Value<int> traktId,
      Value<String> title,
    });
typedef $$ComfortPausedShowsTableUpdateCompanionBuilder =
    ComfortPausedShowsCompanion Function({
      Value<int> traktId,
      Value<String> title,
    });

class $$ComfortPausedShowsTableFilterComposer
    extends Composer<_$ForkDatabase, $ComfortPausedShowsTable> {
  $$ComfortPausedShowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get traktId => $composableBuilder(
    column: $table.traktId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ComfortPausedShowsTableOrderingComposer
    extends Composer<_$ForkDatabase, $ComfortPausedShowsTable> {
  $$ComfortPausedShowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get traktId => $composableBuilder(
    column: $table.traktId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ComfortPausedShowsTableAnnotationComposer
    extends Composer<_$ForkDatabase, $ComfortPausedShowsTable> {
  $$ComfortPausedShowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get traktId =>
      $composableBuilder(column: $table.traktId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);
}

class $$ComfortPausedShowsTableTableManager
    extends
        RootTableManager<
          _$ForkDatabase,
          $ComfortPausedShowsTable,
          ComfortPausedRecord,
          $$ComfortPausedShowsTableFilterComposer,
          $$ComfortPausedShowsTableOrderingComposer,
          $$ComfortPausedShowsTableAnnotationComposer,
          $$ComfortPausedShowsTableCreateCompanionBuilder,
          $$ComfortPausedShowsTableUpdateCompanionBuilder,
          (
            ComfortPausedRecord,
            BaseReferences<
              _$ForkDatabase,
              $ComfortPausedShowsTable,
              ComfortPausedRecord
            >,
          ),
          ComfortPausedRecord,
          PrefetchHooks Function()
        > {
  $$ComfortPausedShowsTableTableManager(
    _$ForkDatabase db,
    $ComfortPausedShowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ComfortPausedShowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ComfortPausedShowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ComfortPausedShowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> traktId = const Value.absent(),
                Value<String> title = const Value.absent(),
              }) => ComfortPausedShowsCompanion(traktId: traktId, title: title),
          createCompanionCallback:
              ({
                Value<int> traktId = const Value.absent(),
                Value<String> title = const Value.absent(),
              }) => ComfortPausedShowsCompanion.insert(
                traktId: traktId,
                title: title,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ComfortPausedShowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ForkDatabase,
      $ComfortPausedShowsTable,
      ComfortPausedRecord,
      $$ComfortPausedShowsTableFilterComposer,
      $$ComfortPausedShowsTableOrderingComposer,
      $$ComfortPausedShowsTableAnnotationComposer,
      $$ComfortPausedShowsTableCreateCompanionBuilder,
      $$ComfortPausedShowsTableUpdateCompanionBuilder,
      (
        ComfortPausedRecord,
        BaseReferences<
          _$ForkDatabase,
          $ComfortPausedShowsTable,
          ComfortPausedRecord
        >,
      ),
      ComfortPausedRecord,
      PrefetchHooks Function()
    >;
typedef $$ShortlistItemsTableCreateCompanionBuilder =
    ShortlistItemsCompanion Function({
      required String itemKey,
      required int position,
      required String title,
      required String itemJson,
      required int addedAt,
      Value<int> rowid,
    });
typedef $$ShortlistItemsTableUpdateCompanionBuilder =
    ShortlistItemsCompanion Function({
      Value<String> itemKey,
      Value<int> position,
      Value<String> title,
      Value<String> itemJson,
      Value<int> addedAt,
      Value<int> rowid,
    });

class $$ShortlistItemsTableFilterComposer
    extends Composer<_$ForkDatabase, $ShortlistItemsTable> {
  $$ShortlistItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get itemKey => $composableBuilder(
    column: $table.itemKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get itemJson => $composableBuilder(
    column: $table.itemJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ShortlistItemsTableOrderingComposer
    extends Composer<_$ForkDatabase, $ShortlistItemsTable> {
  $$ShortlistItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get itemKey => $composableBuilder(
    column: $table.itemKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get itemJson => $composableBuilder(
    column: $table.itemJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ShortlistItemsTableAnnotationComposer
    extends Composer<_$ForkDatabase, $ShortlistItemsTable> {
  $$ShortlistItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get itemKey =>
      $composableBuilder(column: $table.itemKey, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get itemJson =>
      $composableBuilder(column: $table.itemJson, builder: (column) => column);

  GeneratedColumn<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);
}

class $$ShortlistItemsTableTableManager
    extends
        RootTableManager<
          _$ForkDatabase,
          $ShortlistItemsTable,
          ShortlistRecord,
          $$ShortlistItemsTableFilterComposer,
          $$ShortlistItemsTableOrderingComposer,
          $$ShortlistItemsTableAnnotationComposer,
          $$ShortlistItemsTableCreateCompanionBuilder,
          $$ShortlistItemsTableUpdateCompanionBuilder,
          (
            ShortlistRecord,
            BaseReferences<
              _$ForkDatabase,
              $ShortlistItemsTable,
              ShortlistRecord
            >,
          ),
          ShortlistRecord,
          PrefetchHooks Function()
        > {
  $$ShortlistItemsTableTableManager(
    _$ForkDatabase db,
    $ShortlistItemsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ShortlistItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ShortlistItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ShortlistItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> itemKey = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> itemJson = const Value.absent(),
                Value<int> addedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ShortlistItemsCompanion(
                itemKey: itemKey,
                position: position,
                title: title,
                itemJson: itemJson,
                addedAt: addedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String itemKey,
                required int position,
                required String title,
                required String itemJson,
                required int addedAt,
                Value<int> rowid = const Value.absent(),
              }) => ShortlistItemsCompanion.insert(
                itemKey: itemKey,
                position: position,
                title: title,
                itemJson: itemJson,
                addedAt: addedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ShortlistItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$ForkDatabase,
      $ShortlistItemsTable,
      ShortlistRecord,
      $$ShortlistItemsTableFilterComposer,
      $$ShortlistItemsTableOrderingComposer,
      $$ShortlistItemsTableAnnotationComposer,
      $$ShortlistItemsTableCreateCompanionBuilder,
      $$ShortlistItemsTableUpdateCompanionBuilder,
      (
        ShortlistRecord,
        BaseReferences<_$ForkDatabase, $ShortlistItemsTable, ShortlistRecord>,
      ),
      ShortlistRecord,
      PrefetchHooks Function()
    >;
typedef $$ForkSettingsTableCreateCompanionBuilder =
    ForkSettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$ForkSettingsTableUpdateCompanionBuilder =
    ForkSettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$ForkSettingsTableFilterComposer
    extends Composer<_$ForkDatabase, $ForkSettingsTable> {
  $$ForkSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ForkSettingsTableOrderingComposer
    extends Composer<_$ForkDatabase, $ForkSettingsTable> {
  $$ForkSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ForkSettingsTableAnnotationComposer
    extends Composer<_$ForkDatabase, $ForkSettingsTable> {
  $$ForkSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$ForkSettingsTableTableManager
    extends
        RootTableManager<
          _$ForkDatabase,
          $ForkSettingsTable,
          ForkSettingRecord,
          $$ForkSettingsTableFilterComposer,
          $$ForkSettingsTableOrderingComposer,
          $$ForkSettingsTableAnnotationComposer,
          $$ForkSettingsTableCreateCompanionBuilder,
          $$ForkSettingsTableUpdateCompanionBuilder,
          (
            ForkSettingRecord,
            BaseReferences<
              _$ForkDatabase,
              $ForkSettingsTable,
              ForkSettingRecord
            >,
          ),
          ForkSettingRecord,
          PrefetchHooks Function()
        > {
  $$ForkSettingsTableTableManager(_$ForkDatabase db, $ForkSettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ForkSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ForkSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ForkSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ForkSettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => ForkSettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ForkSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$ForkDatabase,
      $ForkSettingsTable,
      ForkSettingRecord,
      $$ForkSettingsTableFilterComposer,
      $$ForkSettingsTableOrderingComposer,
      $$ForkSettingsTableAnnotationComposer,
      $$ForkSettingsTableCreateCompanionBuilder,
      $$ForkSettingsTableUpdateCompanionBuilder,
      (
        ForkSettingRecord,
        BaseReferences<_$ForkDatabase, $ForkSettingsTable, ForkSettingRecord>,
      ),
      ForkSettingRecord,
      PrefetchHooks Function()
    >;
typedef $$SyncStampsTableCreateCompanionBuilder =
    SyncStampsCompanion Function({
      required String unit,
      required int stamp,
      Value<bool> deleted,
      Value<int> rowid,
    });
typedef $$SyncStampsTableUpdateCompanionBuilder =
    SyncStampsCompanion Function({
      Value<String> unit,
      Value<int> stamp,
      Value<bool> deleted,
      Value<int> rowid,
    });

class $$SyncStampsTableFilterComposer
    extends Composer<_$ForkDatabase, $SyncStampsTable> {
  $$SyncStampsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get unit => $composableBuilder(
    column: $table.unit,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get stamp => $composableBuilder(
    column: $table.stamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncStampsTableOrderingComposer
    extends Composer<_$ForkDatabase, $SyncStampsTable> {
  $$SyncStampsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get unit => $composableBuilder(
    column: $table.unit,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get stamp => $composableBuilder(
    column: $table.stamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncStampsTableAnnotationComposer
    extends Composer<_$ForkDatabase, $SyncStampsTable> {
  $$SyncStampsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get unit =>
      $composableBuilder(column: $table.unit, builder: (column) => column);

  GeneratedColumn<int> get stamp =>
      $composableBuilder(column: $table.stamp, builder: (column) => column);

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);
}

class $$SyncStampsTableTableManager
    extends
        RootTableManager<
          _$ForkDatabase,
          $SyncStampsTable,
          SyncStampRecord,
          $$SyncStampsTableFilterComposer,
          $$SyncStampsTableOrderingComposer,
          $$SyncStampsTableAnnotationComposer,
          $$SyncStampsTableCreateCompanionBuilder,
          $$SyncStampsTableUpdateCompanionBuilder,
          (
            SyncStampRecord,
            BaseReferences<_$ForkDatabase, $SyncStampsTable, SyncStampRecord>,
          ),
          SyncStampRecord,
          PrefetchHooks Function()
        > {
  $$SyncStampsTableTableManager(_$ForkDatabase db, $SyncStampsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncStampsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncStampsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncStampsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> unit = const Value.absent(),
                Value<int> stamp = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStampsCompanion(
                unit: unit,
                stamp: stamp,
                deleted: deleted,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String unit,
                required int stamp,
                Value<bool> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStampsCompanion.insert(
                unit: unit,
                stamp: stamp,
                deleted: deleted,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncStampsTableProcessedTableManager =
    ProcessedTableManager<
      _$ForkDatabase,
      $SyncStampsTable,
      SyncStampRecord,
      $$SyncStampsTableFilterComposer,
      $$SyncStampsTableOrderingComposer,
      $$SyncStampsTableAnnotationComposer,
      $$SyncStampsTableCreateCompanionBuilder,
      $$SyncStampsTableUpdateCompanionBuilder,
      (
        SyncStampRecord,
        BaseReferences<_$ForkDatabase, $SyncStampsTable, SyncStampRecord>,
      ),
      SyncStampRecord,
      PrefetchHooks Function()
    >;

class $ForkDatabaseManager {
  final _$ForkDatabase _db;
  $ForkDatabaseManager(this._db);
  $$HomeRowsTableTableManager get homeRows =>
      $$HomeRowsTableTableManager(_db, _db.homeRows);
  $$ComfortPausedShowsTableTableManager get comfortPausedShows =>
      $$ComfortPausedShowsTableTableManager(_db, _db.comfortPausedShows);
  $$ShortlistItemsTableTableManager get shortlistItems =>
      $$ShortlistItemsTableTableManager(_db, _db.shortlistItems);
  $$ForkSettingsTableTableManager get forkSettings =>
      $$ForkSettingsTableTableManager(_db, _db.forkSettings);
  $$SyncStampsTableTableManager get syncStamps =>
      $$SyncStampsTableTableManager(_db, _db.syncStamps);
}
