import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../utils/app_logger.dart';
import 'feed_players.dart';

/// The phone's TMDB trailer rung (plan V2-63, D16): a YouTube video in the
/// YouTube IFrame player, in a WebView.
///
/// What the code relies on, from the IFrame Player API reference
/// (https://developers.google.com/youtube/iframe_api_reference): the API is
/// loaded from `https://www.youtube.com/iframe_api` and calls
/// `onYouTubeIframeAPIReady`; `YT.Player` takes `videoId`, `playerVars` and
/// `events` (`onReady`, `onStateChange` with -1 unstarted, 0 ended, 1
/// playing, 2 paused, 3 buffering, 5 cued, `onError` with 2, 5, 100, 101,
/// 150 and 153, and `onAutoplayBlocked`); the player has `playVideo`,
/// `pauseVideo`, `stopVideo`, `seekTo(seconds, allowSeekAhead)`, `mute`,
/// `unMute`, `setVolume(0-100)`, `getCurrentTime`, `getDuration`,
/// `getVideoLoadedFraction`, `getPlayerState` and `destroy`. There is no
/// quality setter worth calling, so none is attempted. The player parameters
/// (https://developers.google.com/youtube/player_parameters): `autoplay` 0,
/// `controls` 0, `playsinline` 1, `rel` 0, `fs` 0, `disablekb` 1,
/// `iv_load_policy` 3, `enablejsapi` 1 and `origin`. `mute` is not a
/// documented parameter, so the player is muted through the API in
/// `onReady`, before anything plays.
///
/// The Required Minimum Functionality
/// (https://developers.google.com/youtube/terms/required-minimum-functionality)
/// sets the rest: the player identifies the app through the `Referer`, an
/// HTTPS URL whose domain is the app's id (the page is loaded with that as
/// its base URL, so error 153 never fires for a missing Referer); its
/// viewport is at least 200 by 200; nothing is drawn in front of any part of
/// it; and it plays only once it is on screen.
abstract final class ReelYouTube {
  /// What a TMDB `key` must look like to be played: YouTube's id alphabet.
  /// Anything else is dropped, so nothing from a response reaches the page's
  /// script but these characters.
  static final RegExp videoId = RegExp(r'^[A-Za-z0-9_-]{6,32}$');

  /// The smallest viewport the player may have, each way (RMF).
  static const double minSide = 200;

  /// How a YouTube clip travels in a [ClipSource]: the watch URL. Nothing
  /// opens it; the feed sees it and plays the id in the IFrame player.
  static String watchUri(String id) => Uri.https('www.youtube.com', '/watch', {'v': id}).toString();

  /// The video id of a [watchUri], or null for any other address.
  static String? idOf(Uri uri) {
    if (uri.scheme != 'https' || uri.host != 'www.youtube.com' || uri.path != '/watch') return null;
    final id = uri.queryParameters['v'];
    return id != null && videoId.hasMatch(id) ? id : null;
  }

  /// The page's base URL, which YouTube receives as the `Referer` and the
  /// `origin`: `https://<application id>` (RMF "API Client Identity").
  static String? originFor(String appId) {
    final id = appId.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9]+(\.[a-z0-9_]+)+$').hasMatch(id)) return null;
    return 'https://$id';
  }

  /// The page that hosts the player for [id], with [origin] as its origin.
  /// Its script posts JSON to the `ReelYT` channel: `ready`, `state` (`s`),
  /// `tick` (`t` seconds, `d` duration, `l` loaded fraction, `s` state),
  /// `error` (`c`, -1 when the API script didn't load) and `blocked`.
  static String html({required String id, required String origin}) {
    assert(videoId.hasMatch(id));
    final vars = jsonEncode({
      'autoplay': 0,
      'controls': 0,
      'playsinline': 1,
      'rel': 0,
      'fs': 0,
      'disablekb': 1,
      'iv_load_policy': 3,
      'enablejsapi': 1,
      'origin': origin,
    });
    return '''
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden}#p{position:absolute;top:0;left:0;width:100%;height:100%}</style>
</head><body><div id="p"></div>
<script>
var player=null,ready=false,wantPlay=false,vol=0,loop=false,timer=null;
function send(o){try{ReelYT.postMessage(JSON.stringify(o));}catch(e){}}
function tick(){if(!player||!ready)return;send({e:'tick',t:player.getCurrentTime()||0,d:player.getDuration()||0,l:player.getVideoLoadedFraction()||0,s:player.getPlayerState()});}
function applyVolume(){if(!player||!ready)return;if(vol<=0){player.mute();}else{player.unMute();player.setVolume(Math.round(vol*100));}}
function reelPlay(){wantPlay=true;if(ready)player.playVideo();}
function reelPause(){wantPlay=false;if(ready)player.pauseVideo();}
function reelSeek(s){if(ready)player.seekTo(s,true);}
function reelVolume(v){vol=v;applyVolume();}
function reelLoop(on){loop=on;}
function reelStop(){wantPlay=false;if(timer){clearInterval(timer);timer=null;}try{if(player){player.mute();player.stopVideo();player.destroy();}}catch(e){}player=null;ready=false;}
function onYouTubeIframeAPIReady(){
player=new YT.Player('p',{width:'100%',height:'100%',videoId:${jsonEncode(id)},playerVars:$vars,events:{
onReady:function(){ready=true;player.mute();applyVolume();send({e:'ready'});timer=setInterval(tick,250);if(wantPlay)player.playVideo();},
onStateChange:function(ev){if(ev.data===0&&loop){player.seekTo(0,true);player.playVideo();return;}send({e:'state',s:ev.data});tick();},
onError:function(ev){send({e:'error',c:ev.data});},
onAutoplayBlocked:function(){send({e:'blocked'});}
}});}
</script>
<script src="https://www.youtube.com/iframe_api" onerror="send({e:'error',c:-1})"></script>
</body></html>''';
  }
}

/// The WebView under a [YouTubeFeedVideo], kept apart so the player's states
/// can be tested without one.
abstract interface class YouTubeBridge {
  /// Loads [html] with [baseUrl] as its address; completes once the page has
  /// loaded, and throws if it failed to.
  Future<void> load(String html, {required String baseUrl});

  /// Runs [script] in the page; never throws.
  Future<void> run(String script);

  /// What the page's script posts.
  Stream<String> get messages;

  /// The page, drawn.
  Widget view();

  /// Stops everything in the page for good (a blank page replaces it, so no
  /// sound outlives the card) and lets the WebView go.
  Future<void> release();
}

/// A feed player that is not a native decoder but a page (V2-63): it starts
/// silent on every visit, whatever the feed's mute, and makes a sound only
/// after a tap on the sound control, which sits outside the player.
abstract interface class EmbedFeedVideo implements FeedVideo {
  /// Something has played in it (a video, or an ad before one), so its
  /// picture is up. Until then the card's art stays up, behind the page.
  bool get pictureUp;
}

/// What a YouTube player is doing, from its `onStateChange` values.
abstract final class YouTubeState {
  static const unstarted = -1;
  static const ended = 0;
  static const playing = 1;
  static const paused = 2;
  static const buffering = 3;
  static const cued = 5;
}

/// A TMDB trailer in the phone feed (V2-63): the IFrame player behind the
/// [FeedVideo] the feed already drives, so the window, the watchdog, the
/// ramp, the clip-end pref and the failure path all apply as for a native
/// clip.
///
/// * [ready]: the page loaded. The feed then draws the WebView, which is
///   see-through until the player draws, so the player is on screen before
///   it plays; the card's art stays behind it until [pictureUp].
/// * [playing] / [buffering] / [completed]: states 1, 3 and 0.
/// * [failed]: the page didn't load within [openTimeout], the API script
///   didn't load, the player reported an error (embedding disabled is 101 or
///   150; a removed video 100), or the browser blocked playback. The feed
///   then lets it go and the card falls back as for a broken clip.
/// * [setVolume]: 0 mutes, anything else unmutes at that level.
/// * [dispose]: the player is stopped and destroyed, and the page replaced
///   by a blank one, before the WebView is let go.
class YouTubeFeedVideo extends ChangeNotifier implements EmbedFeedVideo {
  YouTubeFeedVideo(this.id, {required this.origin, required this.bridge, this.openTimeout = defaultOpenTimeout}) {
    _sub = bridge.messages.listen(_onMessage);
  }

  final String id;

  /// The page's base URL and the player's `origin` ([ReelYouTube.originFor]
  /// of the app's id); null fails the open.
  final Future<String?> Function() origin;

  /// The page the player lives in.
  final YouTubeBridge bridge;
  final Duration openTimeout;
  late final StreamSubscription<String> _sub;

  /// How long the page may take to load.
  static const Duration defaultOpenTimeout = Duration(seconds: 10);

  bool _loaded = false;
  bool _failed = false;
  bool _disposed = false;
  bool _pictureUp = false;
  int _state = YouTubeState.unstarted;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _fraction = 0;

  @override
  bool get ready => _loaded && !_failed;
  @override
  bool get failed => _failed;
  @override
  bool get pictureUp => _pictureUp && !_failed;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  bool get playing => _state == YouTubeState.playing;
  @override
  bool get buffering => _state == YouTubeState.buffering;
  @override
  bool get completed => _state == YouTubeState.ended;
  @override
  Duration get buffered => _duration * _fraction.clamp(0.0, 1.0);

  @override
  Future<void> initialize() async {
    final sw = Stopwatch()..start();
    try {
      final base = await origin().timeout(openTimeout);
      if (base == null) return _fail('no app id');
      if (_disposed) return;
      await bridge
          .load(
            ReelYouTube.html(id: id, origin: base),
            baseUrl: base,
          )
          .timeout(openTimeout);
      if (_disposed) return;
      _loaded = true;
      appLogger.i('[ReelYT] page loaded ${sw.elapsedMilliseconds}ms');
      notifyListeners();
    } catch (e) {
      _fail('page ${e is TimeoutException ? 'timeout' : 'error'}');
    }
  }

  void _fail(String cause) {
    if (_disposed || _failed) return;
    _failed = true;
    appLogger.i('[ReelYT] failed cause=$cause');
    notifyListeners();
  }

  /// The page's messages are data: only the shapes above are read.
  void _onMessage(String raw) {
    if (_disposed) return;
    final Object? m;
    try {
      m = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (m is! Map) return;
    switch (m['e']) {
      case 'ready':
        appLogger.i('[ReelYT] player ready');
      case 'state':
        if (m['s'] case final int s) _setState(s);
      case 'tick':
        final (t, d, l, s) = (m['t'], m['d'], m['l'], m['s']);
        if (t is num) _position = Duration(milliseconds: (t * 1000).round());
        if (d is num && d > 0) _duration = Duration(milliseconds: (d * 1000).round());
        if (l is num) _fraction = l.toDouble();
        if (s is int) _setState(s, notify: false);
        notifyListeners();
      case 'error':
        final c = m['c'];
        _fail(c == -1 ? 'api script' : 'player error $c');
      case 'blocked':
        _fail('autoplay blocked');
    }
  }

  void _setState(int s, {bool notify = true}) {
    if (s == _state) return;
    _state = s;
    if (s == YouTubeState.playing && !_pictureUp) {
      _pictureUp = true;
      appLogger.i('[ReelYT] playing');
    }
    if (notify) notifyListeners();
  }

  Future<void> _run(String script) async {
    if (_disposed) return;
    await bridge.run(script);
  }

  @override
  Future<void> play() => _run('reelPlay()');
  @override
  Future<void> pause() => _run('reelPause()');

  @override
  Future<void> seekTo(Duration position) {
    _position = position;
    // Off its end: the feed sees it as no longer completed at once.
    if (_state == YouTubeState.ended) _state = YouTubeState.paused;
    return _run('reelSeek(${position.inMilliseconds / 1000})');
  }

  @override
  Future<void> setVolume(double volume) => _run('reelVolume(${volume.clamp(0.0, 1.0)})');

  @override
  Future<void> setLooping(bool looping) => _run('reelLoop($looping)');

  /// How long each step of [dispose] may take before the next goes ahead
  /// anyway, so letting a page go never hangs the feed.
  static const Duration stopTimeout = Duration(seconds: 2);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    // Marked first, so a second call while this one runs does nothing.
    _disposed = true;
    // Silenced and destroyed in the page first, then the page itself goes.
    await _bounded(bridge.run('reelStop()'), 'stop');
    await _sub.cancel();
    await _bounded(bridge.release(), 'release');
    appLogger.i('[ReelYT] released');
    super.dispose();
  }

  static Future<void> _bounded(Future<void> step, String name) async {
    try {
      await step.timeout(stopTimeout);
    } catch (e) {
      appLogger.d('[ReelYT] $name ${e is TimeoutException ? 'timed out' : 'failed'}');
    }
  }

  @override
  Widget view() => bridge.view();
}
