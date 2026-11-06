import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/screens/reel/reel_remote_view.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';

/// Records what the On TV view would send to the TV.
class _Recorder extends CompanionRemoteProvider {
  final sent = <(RemoteCommandType, Map<String, dynamic>?)>[];

  @override
  void sendCommand(RemoteCommandType type, {Map<String, dynamic>? data}) => sent.add((type, data));
}

Map<String, dynamic> _state() => {
  'active': true,
  'deck': 'for-you',
  'deckName': 'For You',
  'decks': [
    {'id': 'for-you', 'name': 'For You'},
    {'id': 'anime-openings', 'name': 'Anime openings'},
  ],
  'playing': true,
  'card': {'id': 't1', 'title': 'Title 1', 'year': 2009},
  'next': [
    for (var i = 2; i <= 4; i++) {'id': 't$i', 'title': 'Title $i'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);

  Future<_Recorder> pump(WidgetTester tester, {Size size = const Size(400, 640)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final remote = _Recorder();
    addTearDown(remote.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<CompanionRemoteProvider>.value(
        value: remote,
        child: const MaterialApp(home: ReelRemoteView()),
      ),
    );
    remote.reelState.value = _state();
    await tester.pumpAndSettle();
    return remote;
  }

  testWidgets('opening it asks the TV for the Reel, then shows its card and the next three', (tester) async {
    final remote = await pump(tester);
    expect(remote.sent.map((s) => s.$1), [RemoteCommandType.tabReel, RemoteCommandType.reelOpen]);
    expect(find.text('Title 1'), findsOneWidget);
    expect(find.text('Up next'), findsOneWidget);
    expect(find.text('Playing on TV'), findsOneWidget);
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
}
