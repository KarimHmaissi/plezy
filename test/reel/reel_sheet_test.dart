import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/screens/reel/reel_sheet.dart';
import 'package:plezy/services/customisation/mirror_store.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_deck_prefs.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/theme/mono_theme.dart';

import 'clip_player_test.dart' show FakeClipEngine;

class _Servers implements ReelServers {
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => [];

  @override
  String? clipUrl(String serverId, String partKey) => null;
}

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async => null;

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

/// An empty deck: the pickers only need its id and name.
class _Deck extends ReelDeck {
  _Deck(this.id, this.name);

  @override
  final String id;
  @override
  final String name;
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;
  @override
  Future<List<ReelCardData>> load() async => const [];
}

/// Both deck pickers (V2-52): the user's order, hidden decks left out, and
/// each deck's second action (move, pin to the top, hide).
void main() {
  late ReelStore store;
  late ReelController c;
  final s = t.reel.decks;

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    final settings = MirrorCustomisationStore({}, send: (_) => true);
    // No device cache here: the last deck isn't kept, which the Reel allows.
    store = ReelStore(database: () async => throw UnsupportedError('no device cache'), settings: () async => settings);
  });

  tearDown(() => c.dispose());

  Future<BuildContext> pump(WidgetTester tester, {ReelDeckPrefs prefs = ReelDeckPrefs.none}) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await store.writeDeckPrefs(prefs, was: ReelDeckPrefs.none);
    c = ReelController(
      decks: [
        _Deck('for-you', 'For You'),
        _Deck('anime-openings', 'Anime openings'),
        _Deck('ai:7', 'Harbor Lights and friends'),
      ],
      resolver: ClipResolver(
        servers: _Servers(),
        store: store,
        aniList: (_) async => null,
        animeThemes: (_) async => const {},
      ),
      clips: ClipPlayer(engine: FakeClipEngine.new),
      store: store,
      media: _Media(),
      onWatch: (_, {required onTv}) async => true,
      addToWatchlist: (_) async => true,
      externalClips: true,
    );
    // Plain futures only (no device cache), so the session starts in the
    // test's own zone.
    await c.start();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return context;
  }

  Finder item(String label) => find.text(label).last;

  List<String> order(WidgetTester tester, List<String> names) => [
    for (final n in names)
      if (find.text(n).evaluate().isNotEmpty) n,
  ]..sort((a, b) => tester.getTopLeft(item(a)).dy.compareTo(tester.getTopLeft(item(b)).dy));

  const names = ['For You', 'Anime openings', 'Harbor Lights and friends'];

  testWidgets('phone: the picker follows the user order, leaves hidden decks out and offers Arrange decks', (
    tester,
  ) async {
    final context = await pump(
      tester,
      prefs: const ReelDeckPrefs(order: ['ai:7'], hidden: {'anime-openings'}),
    );
    unawaited(showReelDeckPicker(context, c));
    await tester.pumpAndSettle();
    expect(order(tester, names), ['Harbor Lights and friends', 'For You']);
    expect(find.text(s.arrange), findsOneWidget);
    expect(find.text(s.arrangeHintPhone), findsOneWidget);
  });

  testWidgets('phone: holding a deck pins it to the top, and the picker comes back in the new order', (tester) async {
    final context = await pump(tester);
    unawaited(showReelDeckPicker(context, c));
    await tester.pumpAndSettle();
    await tester.longPress(item('Harbor Lights and friends'));
    await tester.pumpAndSettle();
    expect(find.text(s.moveToTop), findsOneWidget);
    expect(find.text(s.moveDown), findsNothing, reason: 'it is the last deck');
    await tester.tap(find.text(s.moveToTop));
    await tester.pumpAndSettle();

    expect(find.text(s.arrange), findsOneWidget, reason: 'the picker is back');
    expect(order(tester, names), ['Harbor Lights and friends', 'For You', 'Anime openings']);
    expect((await store.deckPrefs()).order.first, 'ai:7');
  });

  testWidgets('TV: a deck in the long-press sheet hides from its second action', (tester) async {
    final context = await pump(tester);
    final result = Completer<ReelSheetAction?>();
    unawaited(showReelSheet(context, c, isTv: true).then(result.complete));
    await tester.pumpAndSettle();
    expect(find.text(s.arrangeHintTv), findsOneWidget);
    await tester.longPress(item('Anime openings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(s.hide));
    await tester.pumpAndSettle();

    expect(await result.future, ReelSheetAction.deck);
    expect(c.isHidden('anime-openings'), isTrue);
    expect([for (final d in c.shownDecks) d.id], ['for-you', 'ai:7']);
  });

  testWidgets('TV: Arrange decks asks the Reel to open the Decks screen', (tester) async {
    final context = await pump(tester);
    final result = Completer<ReelSheetAction?>();
    unawaited(showReelSheet(context, c, isTv: true).then(result.complete));
    await tester.pumpAndSettle();
    await tester.tap(find.text(s.arrange));
    await tester.pumpAndSettle();
    expect(await result.future, ReelSheetAction.arrangeDecks);
  });
}
