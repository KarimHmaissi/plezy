import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/feed_youtube.dart';
import 'package:plezy/services/reel/feed_youtube_webview.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// The YouTube page bridge on `webview_flutter` (V2-63), over a fake WebView
/// platform: what it loads, which navigations it lets through, and that
/// nothing reaches the page once it has been let go.

const _base = 'https://com.example.reelapp';
const _playerPage = '<html>player for Harbor Lights</html>';

class _FakePlatform extends WebViewPlatform {
  final controllers = <_FakeController>[];

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final c = _FakeController(params);
    controllers.add(c);
    return c;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      _FakeDelegate(params);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params) : super.implementation();

  /// Holds the setup at its first step until completed, when set.
  Completer<void>? hold;
  final loads = <(String, String?)>[];
  final scripts = <String>[];
  JavaScriptChannelParams? channel;
  _FakeDelegate? delegate;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async => hold?.future;

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams javaScriptChannelParams) async =>
      channel = javaScriptChannelParams;

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async =>
      delegate = handler as _FakeDelegate;

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async => loads.add((html, baseUrl));

  @override
  Future<void> runJavaScript(String javaScript) async => scripts.add(javaScript);
}

class _FakeDelegate extends PlatformNavigationDelegate {
  _FakeDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onRequest;
  PageEventCallback? onFinished;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async =>
      onRequest = onNavigationRequest;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async => onFinished = onPageFinished;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async {}
}

void main() {
  late _FakePlatform platform;
  late WebViewPlatform? before;

  setUp(() {
    before = WebViewPlatform.instance;
    platform = _FakePlatform();
    WebViewPlatform.instance = platform;
  });

  tearDown(() {
    if (before != null) WebViewPlatform.instance = before!;
  });

  test('the player page loads at the app\'s address and is ready once it has finished', () async {
    final bridge = WebViewYouTubeBridge();
    final c = platform.controllers.single;
    var done = false;
    final load = bridge.load(_playerPage, baseUrl: _base).then((_) => done = true);
    await pumpEventQueue();
    expect(c.loads, [(_playerPage, _base)]);
    expect(done, isFalse);
    c.delegate!.onFinished!(_base);
    await load;
    expect(done, isTrue);
  });

  test('the page may not take its main frame anywhere else; the player\'s own frame loads', () async {
    final bridge = WebViewYouTubeBridge();
    final c = platform.controllers.single;
    unawaited(bridge.load(_playerPage, baseUrl: _base));
    await pumpEventQueue();
    Future<NavigationDecision> ask(String url, {required bool main}) async =>
        await c.delegate!.onRequest!(NavigationRequest(url: url, isMainFrame: main));
    expect(await ask('$_base/', main: true), NavigationDecision.navigate);
    expect(await ask('https://www.youtube.com/watch?v=AbCdEfGhIj1', main: true), NavigationDecision.prevent);
    expect(await ask('https://www.youtube.com/embed/AbCdEfGhIj1', main: false), NavigationDecision.navigate);
  });

  test('let go while it was being set up: the player page is never loaded over the blank one', () async {
    final bridge = WebViewYouTubeBridge();
    final c = platform.controllers.single..hold = Completer<void>();
    final load = bridge.load(_playerPage, baseUrl: _base);
    await pumpEventQueue();
    await bridge.release();
    c.hold!.complete();
    await load;
    expect(c.loads.map((l) => l.$1), isNot(contains(_playerPage)));
    expect(c.loads, hasLength(1), reason: 'only the blank page');
  });

  test('a load after it was let go loads nothing', () async {
    final bridge = WebViewYouTubeBridge();
    final c = platform.controllers.single;
    await bridge.release();
    await bridge.load(_playerPage, baseUrl: _base);
    expect(c.loads.map((l) => l.$1), isNot(contains(_playerPage)));
  });

  test('once let go, no script reaches the page and nothing it posts comes through', () async {
    final bridge = WebViewYouTubeBridge();
    final c = platform.controllers.single;
    final got = <String>[];
    bridge.messages.listen(got.add);
    unawaited(bridge.load(_playerPage, baseUrl: _base));
    await pumpEventQueue();
    await bridge.run('reelPlay()');
    c.channel!.onMessageReceived(const JavaScriptMessage(message: '{"e":"ready"}'));
    await pumpEventQueue();
    expect(c.scripts, ['reelPlay()']);
    expect(got, ['{"e":"ready"}']);

    await bridge.release();
    await bridge.run('reelPlay()');
    c.channel!.onMessageReceived(const JavaScriptMessage(message: '{"e":"state","s":1}'));
    await pumpEventQueue();
    expect(c.scripts, ['reelPlay()']);
    expect(got, ['{"e":"ready"}']);
  });

  test('a YouTube watch address gets a page player; any other address does not', () {
    expect(youTubeFeedVideoFor(Uri.parse(ReelYouTube.watchUri('AbCdEfGhIj1'))), isA<YouTubeFeedVideo>());
    expect(youTubeFeedVideoFor(Uri.parse('https://server-a.example/library/clip.mp4')), isNull);
  });
}
