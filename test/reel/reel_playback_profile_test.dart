import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/reel_playback_profile.dart';
import 'package:plezy/services/reel_playback_watcher.dart';
import 'package:plezy/services/settings_service.dart';

class _File implements ReelRendition {
  const _File(this.name, {this.height, this.sizeBytes, this.rank = 0});

  final String name;
  @override
  final int? height;
  @override
  final int? sizeBytes;
  @override
  final int rank;

  @override
  String toString() => name;
}

ReelPlaybackProfile _from({
  bool tv = false,
  Size size = const Size(400, 900),
  double ratio = 2.6,
  ReelLink link = ReelLink.unmetered,
  bool dataSaver = false,
}) => ReelPlaybackProfile.from(tv: tv, size: size, devicePixelRatio: ratio, link: link, dataSaver: dataSaver);

void main() {
  group('rules per device', () {
    test('TV: up to 1080, SDR only, the highest bitrate at that height, fitted', () {
      final p = _from(tv: true, size: const Size(960, 540), ratio: 2);
      expect(p.screen, ReelScreen.tv);
      expect(p.maxHeight, 1080);
      expect(p.sdrOnly, isTrue);
      expect(p.largerFileAtHeight, isTrue);
      expect(p.fit, BoxFit.contain);
      expect(p.fillAllowed, isFalse);
    });

    test('a TV on a 720 output caps at 720', () {
      expect(_from(tv: true, size: const Size(1280, 720), ratio: 1).maxHeight, 720);
    });

    test('Fold cover screen upright: up to 720, fitted, fill allowed, on any network', () {
      for (final link in [ReelLink.unmetered, ReelLink.cellular]) {
        final p = _from(link: link);
        expect(p.screen, ReelScreen.compactPortrait);
        expect(p.maxHeight, 720);
        expect(p.fit, BoxFit.contain);
        expect(p.fillAllowed, isTrue);
        expect(p.sdrOnly, isFalse);
      }
    });

    test('Fold inner screen: 1080 on Wi-Fi, 720 on mobile data', () {
      const inner = Size(700, 840);
      expect(_from(size: inner).screen, ReelScreen.large);
      expect(_from(size: inner).maxHeight, 1080);
      expect(_from(size: inner, link: ReelLink.cellular).maxHeight, 720);
      expect(_from(size: inner).fillAllowed, isFalse);
    });

    test('the cover screen turned sideways follows the large rule', () {
      const sideways = Size(900, 400);
      expect(_from(size: sideways).screen, ReelScreen.large);
      expect(_from(size: sideways).maxHeight, 1080);
      expect(_from(size: sideways, link: ReelLink.cellular).maxHeight, 720);
    });

    test('data saver on mobile data lowers the cap to 480 and takes the smaller file', () {
      final p = _from(size: const Size(700, 840), link: ReelLink.cellular, dataSaver: true);
      expect(p.dataSaver, isTrue);
      expect(p.maxHeight, ReelPlaybackProfile.dataSaverHeight);
      expect(p.largerFileAtHeight, isFalse);
    });

    test('data saver does nothing on Wi-Fi', () {
      final p = _from(size: const Size(700, 840), dataSaver: true);
      expect(p.dataSaver, isFalse);
      expect(p.maxHeight, 1080);
    });

    test('a low-resolution screen never streams more than it can show', () {
      // 16:9 fitted to 720 device pixels across is 405 lines tall.
      expect(_from(size: const Size(360, 740), ratio: 2).maxHeight, 480);
    });

    test('an unmeasured screen keeps the rule cap', () {
      final p = _from(size: Size.zero);
      expect(p.screen, ReelScreen.large);
      expect(p.maxHeight, 1080);
    });

    test('equal inputs give equal profiles, so a rebuild with nothing new notifies nobody', () {
      expect(_from(), _from());
      expect(_from().hashCode, _from().hashCode);
      expect(_from(), isNot(_from(link: ReelLink.cellular, size: const Size(700, 840))));
    });
  });

  group('picking a file', () {
    const p1080 = ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 1080);
    const p720 = ReelPlaybackProfile(screen: ReelScreen.compactPortrait, maxHeight: 720);

    test('the tallest height at or below the cap, else the shortest above it', () {
      expect(p720.heightFrom([480, 720, 1080]), 720);
      expect(p720.heightFrom([480, 1080]), 480);
      expect(p720.heightFrom([1080, 2160]), 1080);
      const saver = ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 480);
      expect(saver.heightFrom([720, 1080]), 720, reason: 'the lowest height available above 480');
      expect(p720.heightFrom(const []), isNull);
    });

    test('720 beats 480 under a 1080 cap (no smaller-file fallback across heights)', () {
      final pick = p1080.pick(const [
        _File('480', height: 480, sizeBytes: 10),
        _File('720', height: 720, sizeBytes: 40),
      ]);
      expect(pick?.name, '720');
    });

    test('the best rank plays, whatever its height', () {
      final pick = p1080.pick(const [
        _File('credited-1080', height: 1080, rank: 1),
        _File('creditless-720', height: 720),
      ]);
      expect(pick?.name, 'creditless-720');
    });

    test('at the chosen height the larger file wins; with data saver the smaller one', () {
      const files = [
        _File('small', height: 720, sizeBytes: 20),
        _File('large', height: 720, sizeBytes: 60),
        _File('unknown', height: 720),
      ];
      expect(p720.pick(files)?.name, 'large');
      const saver = ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 720, largerFileAtHeight: false);
      expect(saver.pick(files)?.name, 'small');
    });

    test('ties keep the source order; files of unknown height only when no height is known', () {
      expect(p1080.pick(const [_File('a', height: 720), _File('b', height: 720)])?.name, 'a');
      expect(p1080.pick(const [_File('?'), _File('720', height: 720)])?.name, '720');
      expect(p1080.pick(const [_File('?')])?.name, '?');
      expect(p1080.pick(const <_File>[]), isNull);
    });
  });

  group('the link', () {
    test('mobile data only when it is the only link; offline only when said outright', () {
      expect(reelLinkOf([ConnectivityResult.mobile]), ReelLink.cellular);
      expect(reelLinkOf([ConnectivityResult.mobile, ConnectivityResult.vpn]), ReelLink.cellular);
      expect(reelLinkOf([ConnectivityResult.wifi, ConnectivityResult.mobile]), ReelLink.unmetered);
      expect(reelLinkOf([ConnectivityResult.ethernet]), ReelLink.unmetered);
      expect(reelLinkOf([ConnectivityResult.none]), ReelLink.offline);
      expect(reelLinkOf([ConnectivityResult.other]), ReelLink.unmetered, reason: 'unknown is assumed online');
      expect(reelLinkOf(const []), ReelLink.unmetered);
    });
  });

  group('ReelPlaybackWatcher', () {
    testWidgets('rebuilds when the screen changes, the network changes or the pref does', (tester) async {
      addTearDown(tester.view.reset);
      tester.view
        ..devicePixelRatio = 2.6
        ..physicalSize = const Size(400 * 2.6, 900 * 2.6);
      final links = StreamController<List<ConnectivityResult>>.broadcast();
      addTearDown(links.close);
      final pref = ValueNotifier(ReelCellular.normal);
      addTearDown(pref.dispose);
      final w = ReelPlaybackWatcher(
        isTV: () => false,
        cellular: () => pref.value,
        cellularChanged: pref,
        linkChanges: links.stream,
        checkLink: () async => [ConnectivityResult.wifi],
      );
      addTearDown(w.dispose);
      await tester.pump();
      expect(w.value.screen, ReelScreen.compactPortrait);
      expect(w.value.maxHeight, 720);

      var told = 0;
      w.addListener(() => told++);

      // Unfolded: the inner screen.
      tester.view.physicalSize = const Size(700 * 2.6, 840 * 2.6);
      await tester.pump();
      expect(w.value.screen, ReelScreen.large);
      expect(w.value.maxHeight, 1080);
      expect(told, 1);

      links.add([ConnectivityResult.mobile]);
      await tester.pump();
      expect(w.value.link, ReelLink.cellular);
      expect(w.value.maxHeight, 720);

      pref.value = ReelCellular.dataSaver;
      await tester.pump();
      expect(w.value.maxHeight, ReelPlaybackProfile.dataSaverHeight);
      expect(told, 3);

      // The same metrics again change nothing.
      tester.view.physicalSize = const Size(700 * 2.6, 840 * 2.6);
      await tester.pump();
      expect(told, 3);
    });

    testWidgets('the first connectivity snapshot never overrides a newer change', (tester) async {
      addTearDown(tester.view.reset);
      tester.view
        ..devicePixelRatio = 2.6
        ..physicalSize = const Size(700 * 2.6, 840 * 2.6);
      final links = StreamController<List<ConnectivityResult>>.broadcast(sync: true);
      addTearDown(links.close);
      final first = Completer<List<ConnectivityResult>>();
      final w = ReelPlaybackWatcher(
        isTV: () => false,
        cellular: () => ReelCellular.normal,
        linkChanges: links.stream,
        checkLink: () => first.future,
      );
      addTearDown(w.dispose);
      links.add([ConnectivityResult.mobile]);
      first.complete([ConnectivityResult.wifi]);
      await tester.pump();
      expect(w.value.link, ReelLink.cellular);
    });
  });
}
