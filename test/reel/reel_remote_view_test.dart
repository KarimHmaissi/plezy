import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/screens/reel/reel_remote_view.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/companion_remote/remote_button.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';

/// Records what the On TV view would send to the TV.
class _Recorder extends CompanionRemoteProvider {
  final sent = <(RemoteCommandType, Map<String, dynamic>?)>[];

  @override
  void sendCommand(RemoteCommandType type, {Map<String, dynamic>? data}) => sent.add((type, data));
}

Map<String, dynamic> _state({bool hasClip = false, bool muted = false}) => {
  'active': true,
  'deck': 'for-you',
  'deckName': 'For You',
  'decks': [
    {'id': 'for-you', 'name': 'For You'},
    {'id': 'anime-openings', 'name': 'Anime openings'},
  ],
  'playing': true,
  'hasClip': hasClip,
  'muted': muted,
  'card': {'id': 't1', 'title': 'Title 1', 'year': 2009},
  'next': [
    for (var i = 2; i <= 4; i++) {'id': 't$i', 'title': 'Title $i'},
  ],
};

/// Scrolls the remote's list until [finder] is built and on screen. It
/// moves the list itself: a drag over the card would step the TV.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final list = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
    final position = tester.state<ScrollableState>(list).position;
    position.jumpTo((position.pixels + 150).clamp(0, position.maxScrollExtent));
    await tester.pump();
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);

  Future<_Recorder> pump(
    WidgetTester tester, {
    Size size = const Size(400, 640),
    ReelRemoteView view = const ReelRemoteView(),
    Map<String, dynamic>? state,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final remote = _Recorder();
    addTearDown(remote.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<CompanionRemoteProvider>.value(
        value: remote,
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: view,
        ),
      ),
    );
    remote.reelState.value = state ?? _state();
    await tester.pumpAndSettle();
    return remote;
  }

  testWidgets('opening it asks the TV for the Reel, then shows its card and the next three', (tester) async {
    final remote = await pump(tester);
    expect(remote.sent.map((s) => s.$1), [RemoteCommandType.tabReel, RemoteCommandType.reelOpen]);
    expect(find.text('Title 1'), findsOneWidget);
    expect(find.text('Playing on TV'), findsOneWidget);
    // Below the remote's buttons.
    await _reveal(tester, find.text('Up next'));
    expect(find.text('Up next'), findsOneWidget);
  });

  testWidgets('swiping the card up steps the TV, even on a screen short enough to scroll', (tester) async {
    // The Fold's cover screen: the list scrolls, so a swipe on it must not
    // be taken by the scroll view.
    final remote = await pump(tester, size: const Size(400, 560));
    remote.sent.clear();
    await tester.fling(find.text('Playing on TV'), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();
    expect(remote.sent, hasLength(1));
    expect(remote.sent.single.$1, RemoteCommandType.reelStep);
    expect(remote.sent.single.$2, {'dir': 1});
  });

  testWidgets('swiping the card sideways changes the deck; a tap pauses', (tester) async {
    final remote = await pump(tester);
    remote.sent.clear();
    await tester.fling(find.text('Playing on TV'), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(remote.sent.single.$2, {'deckDir': 1});
    remote.sent.clear();
    await tester.tap(find.text('Playing on TV'));
    await tester.pump();
    expect(remote.sent.single.$2, {'action': 'pause'});
  });

  testWidgets('Save goes to the TV as an action', (tester) async {
    final remote = await pump(tester);
    remote.sent.clear();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(remote.sent.single.$1, RemoteCommandType.reelAction);
    expect(remote.sent.single.$2, {'action': 'save'});
  });

  testWidgets('the TV opens on the deck and the card the phone was on; another deck opens on its own cursor', (
    tester,
  ) async {
    final remote = await pump(
      tester,
      view: const ReelRemoteView(deck: 'for-you', groupKey: 'g-harbor'),
    );
    expect(remote.sent.last.$1, RemoteCommandType.reelOpen);
    expect(remote.sent.last.$2, {'deck': 'for-you', 'groupKey': 'g-harbor'});
    remote.sent.clear();
    await tester.tap(find.text('Anime openings'));
    await tester.pump();
    expect(remote.sent.last.$1, RemoteCommandType.reelOpen);
    expect(remote.sent.last.$2, {'deck': 'anime-openings'});
  });

  group('V2-49: a full remote', () {
    Future<void> press(WidgetTester tester, String label) async {
      final button = find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(RemoteButton)),
        matching: find.byType(FilledButton),
      );
      await _reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('previous and next step the TV; the big button pauses it', (tester) async {
      final remote = await pump(tester);
      remote.sent.clear();
      await press(tester, 'Previous');
      await press(tester, 'Next');
      await press(tester, 'Pause');
      expect(remote.sent.map((s) => s.$2), [
        {'dir': -1},
        {'dir': 1},
        {'action': 'pause'},
      ]);
      expect(remote.sent.map((s) => s.$1), [
        RemoteCommandType.reelStep,
        RemoteCommandType.reelStep,
        RemoteCommandType.reelAction,
      ]);
    });

    testWidgets('the volume row sends mute, down and up to the TV\'s Reel', (tester) async {
      final remote = await pump(tester);
      remote.sent.clear();
      await press(tester, 'Mute');
      await press(tester, 'Down');
      await press(tester, 'Up');
      expect(remote.sent.map((s) => s.$2?['action']), ['mute', 'volumeDown', 'volumeUp']);
    });

    testWidgets('muted on the TV, the mute button offers the sound back', (tester) async {
      await pump(tester, state: _state(muted: true));
      await _reveal(tester, find.text('Sound on'));
      expect(find.text('Sound on'), findsOneWidget);
      expect(find.text('Mute'), findsNothing);
    });

    testWidgets('More offers Details and Seen it; Spoiled me and Replay only with a clip', (tester) async {
      final remote = await pump(tester);
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('Details'), findsOneWidget);
      expect(find.text('Seen it'), findsOneWidget);
      expect(find.text('Spoiled me'), findsNothing);
      expect(find.text('Replay'), findsNothing);
      remote.sent.clear();
      await tester.tap(find.text('Seen it'));
      await tester.pumpAndSettle();
      expect(remote.sent.single.$1, RemoteCommandType.reelAction);
      expect(remote.sent.single.$2, {'action': 'seenIt'});

      remote.reelState.value = _state(hasClip: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('Spoiled me'), findsOneWidget);
      expect(find.text('Replay'), findsOneWidget);
      remote.sent.clear();
      await tester.tap(find.text('Spoiled me'));
      await tester.pumpAndSettle();
      expect(remote.sent.single.$2, {'action': 'spoiled'});
    });

    testWidgets('the deck chips take their own height at large text instead of a fixed 48 px', (tester) async {
      await pump(tester, textScale: 2);
      final chip = tester.getRect(find.widgetWithText(ChoiceChip, 'For You'));
      expect(chip.height, greaterThan(48));
      // Whole, not clipped by the strip: the card starts below it.
      expect(tester.getRect(find.text('Playing on TV')).top, greaterThan(chip.bottom));
      expect(tester.takeException(), isNull);
    });
  });
}
