// The fake engine's controllers are closed with the test.
// ignore_for_file: close_sinks
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/reel/reel_stuck.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_deck_prefs.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/utils/app_logger.dart';

import 'clip_player_test.dart' show FakeClipEngine;

/// The Shield's long-standby spin (2026-11-06 smoke): every wait on the way
/// to a card is bounded, nothing in flight is joined across a suspend, each
/// start logs its stage, and a card that shows nothing in time is reported
/// as stuck with a retry.

/// One trailer per title; a title in [hang] answers only when its gate
/// opens (a stale server connection after a long standby).
class _Servers implements ReelServers {
  final Map<String, Completer<void>> hang = {};
  final Set<String> bare = {};
  int reads = 0;

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    reads++;
    await hang[ratingKey]?.future;
    if (bare.contains(ratingKey)) return const [];
    return [
      PlexExtraClip(
        ratingKey: 'x$ratingKey',
        title: 'Trailer',
        partKey: '/iva/$ratingKey.mp4',
        subtype: 'trailer',
        index: 0,
      ),
    ];
  }

  @override
  String? clipUrl(String serverId, String partKey) => 'https://cdn.example$partKey';
}

/// Metadata that never lands while [hang] is set.
class _Media implements ReelMedia {
  Completer<void>? hang;

  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async {
    await hang?.future;
    return MediaItem(id: ratingKey, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Harbor Lights');
  }

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) => item(serverId, ratingKey);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

/// A deck whose loads wait on [gates] in turn (none left: at once).
class _Deck extends ReelDeck {
  _Deck(this.ids);

  final List<String> ids;
  final List<Completer<void>> gates = [];
  int loads = 0;

  @override
  String get id => 'a';

  @override
  String get name => 'Deck A';

  @override
  bool get keepsSeen => true;

  @override
  bool get raw => true;

  @override
  Future<List<ReelCardData>> load() async {
    final n = loads++;
    if (n < gates.length) await gates[n].future;
    return [for (final id in ids) _card(id)];
  }
}

/// The Reel's store with a deck prefs read that waits on [prefsGate].
class _Store extends ReelStore {
  _Store(ForkDatabase db, LocalCustomisationStore settings)
    : super(database: () async => db, settings: () async => settings);

  Completer<void>? prefsGate;
  int prefsReads = 0;

  /// Holds every event write while set (a slow database).
  Completer<void>? recordGate;

  @override
  Future<void> record(String titleId, ReelAction action, {String deck = '', int? seconds}) async {
    await recordGate?.future;
    return super.record(titleId, action, deck: deck, seconds: seconds);
  }

  @override
  Future<ReelDeckPrefs> deckPrefs() async {
    prefsReads++;
    await prefsGate?.future;
    return super.deckPrefs();
  }
}

ReelCardData _card(String id) => ReelCardData(
  title: ReelTitle(
    titleId: 't$id',
    groupKey: 'g$id',
    title: 'Harbor Lights',
    isShow: false,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: 't$id', groupKey: 'g$id'),
    seen: SeenState.unseen,
  ),
  best: IndexedTitle(
    id: 's1:$id',
    serverId: 's1',
    serverName: 'Server A',
    libraryKey: '1',
    libraryTitle: 'Films',
    ratingKey: id,
    type: 'movie',
    title: 'Harbor Lights',
    genres: '',
    countries: '',
    directors: '',
    writers: '',
    cast: '',
    collections: '',
    groupKey: 'g$id',
    summary: '',
  ),
);

/// Short enough to run out inside a test, long enough for everything that
/// does answer.
const _limit = Duration(milliseconds: 80);

/// Generous: the waits these tests don't time out.
const _never = ReelTimeouts.all(Duration(minutes: 5));

Future<void> _wait([Duration d = const Duration(milliseconds: 20)]) => Future<void>.delayed(d);

List<String> _log(String prefix) =>
    MemoryLogOutput.getLogs().map((e) => e.message).where((m) => m.startsWith(prefix)).toList().reversed.toList();

void main() {
  late ForkDatabase db;
  late _Store store;
  late _Servers servers;
  late _Media media;
  late _Deck deck;
  late List<FakeClipEngine> engines;
  final made = <ReelController>[];

  /// Every core built while set opens nothing until it completes.
  Completer<void>? openGate;

  setUp(() {
    db = ForkDatabase.memory();
    store = _Store(db, LocalCustomisationStore(db));
    servers = _Servers();
    media = _Media();
    deck = _Deck(['1', '2', '3']);
    engines = [];
    openGate = null;
    MemoryLogOutput.clearLogs();
  });

  tearDown(() async {
    for (final c in made) {
      c.dispose();
    }
    made.clear();
    await db.close();
  });

  ReelController make({
    bool externalClips = false,
    ReelTimeouts timeouts = _never,
    Duration? stuckAfter,
    Duration openLimit = ClipPlayer.defaultOpenLimit,
  }) {
    final c = ReelController(
      decks: [deck],
      resolver: ClipResolver(
        servers: servers,
        store: store,
        aniList: (_) async => null,
        animeThemes: (_) async => const {},
      ),
      clips: ClipPlayer(
        engine: () {
          final e = FakeClipEngine()..openGate = openGate;
          engines.add(e);
          return e;
        },
        openLimit: openLimit,
      ),
      store: store,
      media: media,
      onWatch: (_, {required onTv}) async => false,
      addToWatchlist: (_) async => true,
      externalClips: externalClips,
    );
    c.timeouts = timeouts;
    c.stuckAfter = stuckAfter;
    made.add(c);
    return c;
  }

  group('every wait on the way to a card is bounded', () {
    test('a deck load that never comes back fails in time, and the next start loads afresh', () async {
      deck.gates.add(Completer<void>()); // the first load never lands
      final c = make(timeouts: ReelTimeouts.all(_limit));
      await c.start().timeout(const Duration(seconds: 5));
      expect(c.current.kind, ReelSlotKind.failed);
      expect(c.stage, ReelStage.still);

      await c.suspend();
      await c.start().timeout(const Duration(seconds: 5));
      expect(deck.loads, 2);
      expect(c.current.card?.id, 't1');
    });

    test('a deck load still in flight at a suspend is never joined by the next start', () async {
      deck.gates.add(Completer<void>()); // hangs, and nothing times it out
      final c = make();
      unawaited(c.start());
      await _wait();
      expect(c.current.kind, ReelSlotKind.loading);

      await c.suspend();
      await c.start().timeout(const Duration(seconds: 5));
      expect(deck.loads, 2);
      expect(c.current.card?.id, 't1');
      // The dropped load landing late changes nothing on screen.
      deck.gates.first.complete();
      await _wait();
      expect(c.current.card?.id, 't1');
      expect(c.current.kind, ReelSlotKind.card);
    });

    test('a deck prefs read that hangs gives way, and is read again after a suspend', () async {
      store.prefsGate = Completer<void>();
      final c = make(timeouts: const ReelTimeouts(store: _limit));
      await c.start().timeout(const Duration(seconds: 5));
      expect(c.current.card?.id, 't1');
      expect(store.prefsReads, 1);

      store.prefsGate = null;
      await c.suspend();
      await c.start().timeout(const Duration(seconds: 5));
      expect(store.prefsReads, 2, reason: 'a failed read is not kept');
    });

    test('a clip lookup that never answers leaves a still, and is looked up again on the next start', () async {
      servers.hang['1'] = Completer<void>();
      final c = make(timeouts: const ReelTimeouts(lookup: _limit));
      await c.start().timeout(const Duration(seconds: 5));
      expect(c.current.card?.id, 't1');
      expect(c.current.resolved, isTrue);
      expect(c.current.clip, isNull);
      expect(c.stage, ReelStage.still);
      expect(engines.where((e) => e.calls.any((x) => x.startsWith('open'))), isEmpty);

      servers.hang['1']!.complete();
      await c.suspend();
      await c.start().timeout(const Duration(seconds: 5));
      expect(c.current.clip, isNotNull);
      expect(engines.last.calls, contains('open https://cdn.example/iva/1.mp4'));
    });

    test('a lookup dropped by a suspend writes nothing when it lands', () async {
      servers.hang['1'] = Completer<void>();
      final c = make();
      unawaited(c.start());
      await _wait();
      expect(c.current.resolved, isFalse);

      await c.suspend();
      servers.hang['1']!.complete();
      await _wait();
      expect(c.current.resolved, isFalse, reason: 'the next start looks it up afresh');

      await c.start().timeout(const Duration(seconds: 5));
      expect(c.current.clip, isNotNull);
    });

    test("a card's metadata that never lands reads as missed in time", () async {
      media.hang = Completer<void>();
      final c = make(timeouts: const ReelTimeouts(metadata: _limit));
      await c.start();
      expect(c.current.itemMissed, isFalse);
      await _wait(_limit * 3);
      expect(c.current.item, isNull);
      expect(c.current.itemMissed, isTrue);
    });

    test('TV: a clip open that never comes back lets the core go, and the card falls back', () async {
      final c = make(openLimit: _limit);
      final gate = openGate = Completer<void>();
      await c.start().timeout(const Duration(seconds: 5));
      await _wait(_limit * 3);
      expect(engines.first.disposed, isTrue, reason: 'the wedged core is let go');
      expect(c.clips.engine, isNot(same(engines.first)));
      // Its one trailer failed: the card is a still now.
      expect(c.current.clip, isNull);
      expect(c.stage, ReelStage.still);
      gate.complete();
    });

    test('a start waits for the suspend before it, so the core it opens is never the one released', () async {
      final c = make();
      await c.start();
      final first = engines.single;
      // The suspend is still writing how the card was left when the next
      // start (a tab shown again, a resume) comes in.
      store.recordGate = Completer<void>();
      first.disposeGate = Completer<void>();
      unawaited(c.suspend());
      final start = c.start();
      await _wait();
      store.recordGate!.complete();
      await _wait();
      first.disposeGate!.complete();
      await start.timeout(const Duration(seconds: 5));
      expect(first.disposed, isTrue);
      expect(engines, hasLength(2));
      expect(c.clips.engine, same(engines.last));
      expect(engines.last.disposed, isFalse);
      expect(c.clips.phase.value, ClipPhase.loading);
    });
  });

  group('[ReelStart] stage log', () {
    test('each start logs its beginning, the stage it reached, and the first frame that settles it', () async {
      final c = make();
      await c.start();
      final lines = _log('[ReelStart]');
      expect(lines, hasLength(2));
      expect(lines[0], startsWith('[ReelStart] #1 begin gen=0'));
      expect(lines[1], matches(RegExp(r'^\[ReelStart\] #1 shown stage=frame gen=\d+ \d+ms$')));
      expect(c.stage, ReelStage.frame);

      engines.single.firstFrameCtl.add(null);
      expect(c.stage, ReelStage.playing);
      expect(_log('[ReelStart]').last, matches(RegExp(r'^\[ReelStart\] #1 settled stage=playing gen=\d+ \d+ms$')));
    });

    test('a start a suspend overtakes says so', () async {
      deck.gates.add(Completer<void>());
      final c = make();
      final start = c.start();
      await _wait();
      await c.suspend();
      deck.gates.first.complete();
      await start;
      expect(_log('[ReelStart]').last, startsWith('[ReelStart] #1 superseded stage=idle'));
    });
  });

  group('stuck-card watchdog', () {
    const after = Duration(milliseconds: 60);

    test('TV: no first frame in time is stuck at its stage; the first frame clears it', () async {
      final c = make(stuckAfter: after);
      await c.start();
      expect(c.stuck.value, isNull);
      await _wait(after * 2);
      expect(c.stuck.value?.stage, ReelStage.frame);
      expect(_log('[ReelStuck]').single, startsWith('[ReelStuck] stage=frame gen='));

      engines.single.firstFrameCtl.add(null);
      expect(c.stuck.value, isNull);
    });

    test('a deck that never loads is stuck at load', () async {
      deck.gates.add(Completer<void>());
      final c = make(stuckAfter: after);
      unawaited(c.start());
      await _wait(after * 2);
      expect(c.stuck.value?.stage, ReelStage.load);
      expect(c.current.kind, ReelSlotKind.loading);
    });

    test('a still settles at once: an AI card is never stuck', () async {
      servers.bare.add('1');
      final c = make(stuckAfter: after);
      await c.start();
      expect(c.current.isAiCard, isTrue);
      await _wait(after * 2);
      expect(c.stuck.value, isNull);
      expect(c.stage, ReelStage.still);
    });

    test('a step starts the watchdog again for the card it lands on', () async {
      final c = make(stuckAfter: after);
      await c.start();
      await _wait(after * 2);
      expect(c.stuck.value, isNotNull);
      await c.step(1);
      expect(c.stuck.value, isNull);
      await _wait(after * 2);
      expect(c.stuck.value, isNotNull, reason: 'card 2 shows no frame either');
    });

    test('a suspend clears it and times nothing', () async {
      final c = make(stuckAfter: after);
      await c.start();
      await c.suspend();
      await _wait(after * 2);
      expect(c.stuck.value, isNull);
    });

    test('phone: a feed player that never starts is stuck; its start clears it', () async {
      final c = make(externalClips: true, stuckAfter: after);
      await c.start();
      await _wait(after * 2);
      expect(c.stuck.value?.stage, ReelStage.frame);
      c.clipStarted('t1');
      expect(c.stuck.value, isNull);
      expect(c.stage, ReelStage.playing);
    });
  });

  group('the stuck notice', () {
    const after = Duration(milliseconds: 60);

    Future<void> pumpLayer(WidgetTester tester, ReelController c, VoidCallback onRetry) => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ReelStuckLayer(controller: c, tv: false, onRetry: onRetry),
        ),
      ),
    );

    testWidgets('phone: a stuck card shows the notice over it, and a tap is the retry', (tester) async {
      final c = make(externalClips: true, stuckAfter: after);
      await tester.runAsync(() async {
        await c.start();
        await _wait(after * 2);
      });
      var retries = 0;
      await pumpLayer(tester, c, () => retries++);
      await tester.pumpAndSettle();
      expect(find.text('This is taking a while'), findsOneWidget);
      expect(find.text('Tap to try again.'), findsOneWidget);
      await tester.tap(find.text('This is taking a while'));
      expect(retries, 1);
      c.clipStarted('t1');
      await tester.pumpAndSettle();
      expect(find.text('This is taking a while'), findsNothing);
    });

    testWidgets('a deck that never loaded gets the message with Try again', (tester) async {
      deck.gates.add(Completer<void>());
      final c = make(externalClips: true, stuckAfter: after);
      await tester.runAsync(() async {
        unawaited(c.start());
        await _wait(after * 2);
      });
      var retries = 0;
      await pumpLayer(tester, c, () => retries++);
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retries, 1);
      // Unblock the stuck load before the database closes.
      deck.gates.first.complete();
      await tester.runAsync(_wait);
    });
  });
}
