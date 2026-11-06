import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/services/companion_remote/companion_remote_receiver.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';

void main() {
  testWidgets('Back command dispatches semantic gamepad B events', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final events = <KeyEvent>[];
    var actions = 0;
    var exits = 0;
    final chromeController = PlayerChromeController();
    addTearDown(chromeController.dispose);
    final coordinator = PlayerNavigationCoordinator(
      chromeController: chromeController,
      isPromptOpen: () => false,
      dismissPrompt: () {},
      isChromePresented: () => chromeController.controlsPresented,
      exitFullscreenIfActive: () async => false,
      exitPlayer: () => exits++,
      navigateHome: () {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          focusNode: focusNode,
          onKeyEvent: (_, event) {
            events.add(event);
            final navigationKey = classifyPlayerNavigationKey(event, isAppleTV: false);
            return handlePlayerNavigationKeyAction(event, navigationKey, () {
              actions++;
              coordinator.handle(navigationKey);
            });
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();

    CompanionRemoteReceiver.instance.handleCommand(const RemoteCommand(type: RemoteCommandType.back), null);
    await tester.pump();

    expect(events, hasLength(2));
    expect(events.first, isA<KeyDownEvent>());
    expect(events.last, isA<KeyUpEvent>());
    expect(events.map((event) => event.logicalKey), everyElement(LogicalKeyboardKey.gameButtonB));
    expect(events.map((event) => event.deviceType), everyElement(ui.KeyEventDeviceType.directionalPad));
    expect(actions, 1);
    expect(chromeController.controlsVisible, isFalse);
    expect(exits, 0);
  });

  group('music transport', () {
    final receiver = CompanionRemoteReceiver.instance;
    late List<RemoteCommandType> routed;

    setUp(() {
      routed = [];
      receiver.musicTransport = (type) {
        routed.add(type);
        return true;
      };
    });

    tearDown(() {
      receiver.musicTransport = null;
      receiver.playerOwner = null;
      receiver.onSeekForward = null;
    });

    test('transport buttons reach the music session while no video player owns them', () {
      for (final type in const [
        RemoteCommandType.playPause,
        RemoteCommandType.play,
        RemoteCommandType.pause,
        RemoteCommandType.nextTrack,
        RemoteCommandType.previousTrack,
        RemoteCommandType.seekForward,
        RemoteCommandType.seekBackward,
        RemoteCommandType.stop,
      ]) {
        receiver.handleCommand(RemoteCommand(type: type), null);
      }
      receiver.handleCommand(const RemoteCommand(type: RemoteCommandType.volumeUp), null);

      expect(routed, const [
        RemoteCommandType.playPause,
        RemoteCommandType.play,
        RemoteCommandType.pause,
        RemoteCommandType.nextTrack,
        RemoteCommandType.previousTrack,
        RemoteCommandType.seekForward,
        RemoteCommandType.seekBackward,
        RemoteCommandType.stop,
      ]);
    });

    test('a video player owning the transport slots keeps them', () {
      var seeks = 0;
      receiver.playerOwner = Object();
      receiver.onSeekForward = () => seeks++;

      receiver.handleCommand(const RemoteCommand(type: RemoteCommandType.seekForward), null);

      expect(routed, isEmpty);
      expect(seeks, 1);
    });
  });

  test('fork: On TV mode commands reach the Reel callbacks', () {
    final receiver = CompanionRemoteReceiver.instance;
    final got = <String>[];
    receiver.onTabReel = () => got.add('tab');
    receiver.onReelOpen = (d) => got.add('open ${d['deck']}');
    receiver.onReelStep = (d) => got.add('step ${d['dir']}');
    receiver.onReelAction = (a) => got.add('action $a');
    addTearDown(() {
      receiver.onTabReel = null;
      receiver.onReelOpen = null;
      receiver.onReelStep = null;
      receiver.onReelAction = null;
    });

    receiver.handleCommand(const RemoteCommand(type: RemoteCommandType.tabReel), null);
    receiver.handleCommand(const RemoteCommand(type: RemoteCommandType.reelOpen, data: {'deck': 'for-you'}), null);
    receiver.handleCommand(const RemoteCommand(type: RemoteCommandType.reelStep, data: {'dir': 1}), null);
    receiver.handleCommand(const RemoteCommand(type: RemoteCommandType.reelAction, data: {'action': 'save'}), null);
    receiver.handleCommand(const RemoteCommand(type: RemoteCommandType.reelAction), null);
    receiver.handleCommand(const RemoteCommand(type: RemoteCommandType.reelState, data: {'active': true}), null);

    expect(got, ['tab', 'open for-you', 'step 1', 'action save']);
  });

  test('fork: Reel commands are appended, so older peers keep their indexes', () {
    final values = RemoteCommandType.values;
    expect(values.indexOf(RemoteCommandType.catchUpNudge), lessThan(values.indexOf(RemoteCommandType.tabReel)));
    expect(values.sublist(values.length - 5), [
      RemoteCommandType.tabReel,
      RemoteCommandType.reelOpen,
      RemoteCommandType.reelStep,
      RemoteCommandType.reelAction,
      RemoteCommandType.reelState,
    ]);
    final json = const RemoteCommand(type: RemoteCommandType.reelState).toJson();
    expect(RemoteCommand.fromJson(json).type, RemoteCommandType.reelState);
  });
}
