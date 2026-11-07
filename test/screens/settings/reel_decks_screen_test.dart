import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/reel_decks_screen.dart';
import 'package:plezy/services/customisation/mirror_store.dart';
import 'package:plezy/services/reel/reel_deck_prefs.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';

void main() {
  late MirrorCustomisationStore settings;
  late ReelStore store;
  var connected = true;

  const decks = <ReelDeckInfo>[
    (id: 'for-you', name: 'For You'),
    (id: 'anime-openings', name: 'Anime openings'),
    (id: 'ai:7', name: 'Harbor Lights and friends'),
  ];

  setUp(() {
    connected = true;
    settings = MirrorCustomisationStore({}, send: (_) => connected);
    store = ReelStore(
      database: () async => throw UnimplementedError('no device cache here'),
      settings: () async => settings,
    );
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  final s = t.reel.decks;

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: ReelDecksScreen(decks: (_) async => decks, store: store),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder tile(String name) => find.descendant(of: find.byType(FocusableListTile), matching: find.text(name));

  List<String> listed(WidgetTester tester) => [
    for (final name in decks.map((d) => d.name))
      if (tile(name).evaluate().isNotEmpty) name,
  ]..sort((a, b) => tester.getTopLeft(tile(a)).dy.compareTo(tester.getTopLeft(tile(b)).dy));

  Future<void> pick(WidgetTester tester, String deck, String action) async {
    await tester.tap(tile(deck));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action).last);
    await tester.pumpAndSettle();
  }

  testWidgets('lists every deck in the app order, For You as the start deck', (tester) async {
    await pump(tester);
    expect(find.text(s.title), findsOneWidget);
    expect(find.text(s.startOn), findsOneWidget);
    expect(listed(tester), ['For You', 'Anime openings', 'Harbor Lights and friends']);
    expect(find.text(s.syncedNote), findsOneWidget);
  });

  testWidgets('a deck pinned to the top is kept and listed first', (tester) async {
    await pump(tester);
    await pick(tester, 'Harbor Lights and friends', s.moveToTop);
    expect(listed(tester), ['Harbor Lights and friends', 'For You', 'Anime openings']);
    expect((await store.deckPrefs()).order, ['ai:7', 'for-you', 'anime-openings']);
  });

  testWidgets('move down, then hide and show again', (tester) async {
    await pump(tester);
    await pick(tester, 'For You', s.moveDown);
    expect(listed(tester), ['Anime openings', 'For You', 'Harbor Lights and friends']);

    await pick(tester, 'Anime openings', s.hide);
    expect(find.text(s.hiddenDescription), findsOneWidget);
    expect((await store.deckPrefs()).hidden, {'anime-openings'});

    await pick(tester, 'Anime openings', s.show);
    expect(find.text(s.hiddenDescription), findsNothing);
    expect((await store.deckPrefs()).hidden, isEmpty);
  });

  testWidgets('the last shown deck has no Hide', (tester) async {
    await store.writeDeckPrefs(const ReelDeckPrefs(hidden: {'for-you', 'ai:7'}), was: ReelDeckPrefs.none);
    await pump(tester);
    await tester.tap(tile('Anime openings'));
    await tester.pumpAndSettle();
    expect(find.text(s.hide), findsNothing);
    expect(find.text(s.moveUp), findsOneWidget);
  });

  testWidgets('"Where I left off" is kept as the start deck', (tester) async {
    await pump(tester);
    await tester.tap(find.text(s.startLast));
    await tester.pumpAndSettle();
    expect((await store.deckPrefs()).start, ReelStartDeck.last);
  });

  testWidgets('a change that could not be kept goes back and says so', (tester) async {
    await pump(tester);
    connected = false;
    await pick(tester, 'For You', s.moveDown);
    expect(listed(tester), ['For You', 'Anime openings', 'Harbor Lights and friends']);
    expect(find.text(s.saveFailed), findsOneWidget);
  });

  test('every deck has an icon; answers share one', () {
    expect(reelDeckIcon('ai:1'), reelDeckIcon('ai:2'));
    expect({for (final d in decks) reelDeckIcon(d.id)}, hasLength(3));
    final builtIn = [
      'for-you',
      'fits-tonight',
      'another-go',
      'new-this-week',
      'person',
      'anime-openings',
      'most-watched',
    ];
    expect({for (final id in builtIn) reelDeckIcon(id)}, hasLength(builtIn.length), reason: 'each its own');
    expect(builtIn.map(reelDeckIcon), isNot(contains(reelDeckIcon('ai:1'))));
  });
}
