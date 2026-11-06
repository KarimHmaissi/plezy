import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../utils/app_logger.dart';
import 'feed_youtube.dart';

/// The app's YouTube origin (`https://<application id>`, V2-63), read once.
Future<String?> appYouTubeOrigin() => _origin ??= PackageInfo.fromPlatform()
    .then<String?>((p) => ReelYouTube.originFor(p.packageName))
    .catchError((Object _) {
      _origin = null;
      return null;
    });
Future<String?>? _origin;

/// A TMDB trailer's player for the phone feed, or null when [uri] isn't one.
YouTubeFeedVideo? youTubeFeedVideoFor(Uri uri) {
  final id = ReelYouTube.idOf(uri);
  if (id == null) return null;
  return YouTubeFeedVideo(id, origin: appYouTubeOrigin, bridge: WebViewYouTubeBridge());
}

/// [YouTubeBridge] on `webview_flutter` 4.14.1 (Android: `webview_flutter_android`
/// 4.14.1, drawn as a texture-layer platform view, so the page slides with
/// its card).
///
/// * Media may start from script (`setMediaPlaybackRequiresUserGesture`
///   false, Android only): the feed asks the player to play once its card is
///   on screen, and unmutes it from the sound control outside the frame,
///   neither of which is a tap inside the page.
/// * The page is loaded with `loadHtmlString(html, baseUrl: origin)`
///   (Android `loadDataWithBaseURL`), so the player's requests carry the
///   app's id as their `Referer`.
/// * The page may never navigate its main frame away from its own address
///   (a link in the player would otherwise open YouTube inside the card);
///   the player's own frame loads as it needs.
/// * The WebView is see-through: the card's art shows behind the page until
///   the player draws over it.
/// * `webview_flutter` has no dispose: the WebView is freed when its
///   controller is collected. So [release] first replaces the page with a
///   blank one, which ends every sound and request of the player at once.
class WebViewYouTubeBridge implements YouTubeBridge {
  WebViewYouTubeBridge() : _c = WebViewController();

  final WebViewController _c;
  final StreamController<String> _messages = StreamController<String>.broadcast();
  bool _released = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> load(String html, {required String baseUrl}) async {
    final loaded = Completer<void>();
    await _c.setJavaScriptMode(JavaScriptMode.unrestricted);
    // See-through until the player draws, so the card's art shows behind
    // the page (never in front of the player).
    await _c.setBackgroundColor(Colors.transparent);
    await _c.addJavaScriptChannel(
      'ReelYT',
      onMessageReceived: (m) {
        if (!_released && !_messages.isClosed) _messages.add(m.message);
      },
    );
    await _c.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) {
          if (!loaded.isCompleted) loaded.complete();
        },
        onWebResourceError: (e) {
          if ((e.isForMainFrame ?? false) && !loaded.isCompleted) {
            loaded.completeError(StateError('page error ${e.errorCode}'));
          }
        },
        // The page's own address (where a platform reports its load) is let
        // through; any other main-frame load is not.
        onNavigationRequest: (r) => !r.isMainFrame || r.url == baseUrl || r.url == '$baseUrl/'
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ),
    );
    final platform = _c.platform;
    if (platform is AndroidWebViewController) await platform.setMediaPlaybackRequiresUserGesture(false);
    await _c.loadHtmlString(html, baseUrl: baseUrl);
    return loaded.future;
  }

  @override
  Future<void> run(String script) async {
    if (_released) return;
    try {
      await _c.runJavaScript(script);
    } catch (e) {
      appLogger.d('[ReelYT] script call failed', error: e);
    }
  }

  @override
  Widget view() => WebViewWidget(controller: _c);

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    unawaited(_messages.close());
    try {
      await _c.loadHtmlString('<!doctype html><html><body style="background:#000"></body></html>');
    } catch (e) {
      appLogger.d('[ReelYT] blank page failed', error: e);
    }
  }
}
