# video\_player\_android

The Android implementation of [`video_player`][1].

## Usage

This package is [endorsed][2], which means you can simply use `video_player`
normally. This package will be automatically included in your app when you do,
so you do not need to add it to your `pubspec.yaml`.

However, if you `import` this package to use any of its APIs directly, you
should add it to your `pubspec.yaml` as usual.

## Known issues

Using `VideoViewType.platformView` is not currently recommended on Android due to a known [issue][3] affecting platform views on Android.

[1]: https://pub.dev/packages/video_player
[2]: https://flutter.dev/to/endorsed-federated-plugin
[3]: https://github.com/flutter/flutter/issues/164899

## Plezy fork

This is `video_player_android` **2.12.2** from pub.dev (archive sha256
`d27054dea34d748a44f06d433a57005d2aac69944485b0abbaed3303dbcfa3f1`), vendored
so the Reel's phone feed can give each of its players a short buffer. The app
wires it in through `dependency_overrides` (and a direct path dependency, since
`lib/services/reel/feed_players.dart` imports it). Every hand-written change
from upstream is marked `PLEZY DELTA` in the source; the two Pigeon outputs
carry no markers. All of them are listed here.

### What it adds

`AndroidBufferedVideoPlayerOptions` (a `VideoPlayerOptions` from the platform
interface) carries a `BufferDurationsMs`: the four values of media3's
`DefaultLoadControl.Builder.setBufferDurationsMs(minBufferMs, maxBufferMs,
bufferForPlaybackMs, bufferForPlaybackAfterRebufferMs)`. `video_player` hands
its options to the platform unchanged, so only a controller built with these
options gets them; every other player keeps media3's default load control,
exactly as upstream. Each player built with them logs one line under the
logcat tag `PlezyLoadControl`.

### Every change from upstream 2.12.2

Not vendored:
- `example/` (the published example app).
- `AUTHORS` (upstream's contributor list; `LICENSE` is kept unchanged).

Changed:
- `pigeons/messages.dart`: `CreationOptions` gains four nullable ints after
  `backBufferDurationMs`: `minBufferMs`, `maxBufferMs`, `bufferForPlaybackMs`,
  `bufferForPlaybackAfterRebufferMs`.
- `lib/src/messages.g.dart`: regenerated with Pigeon 27.3.2 (the version the
  published outputs name), then `dart format --page-width 100`. The only
  difference is the four new `CreationOptions` fields.
- `android/src/main/kotlin/io/flutter/plugins/videoplayer/Messages.kt`: the
  same four fields, taken from the Pigeon 27.3.2 output and laid out like
  upstream's formatted file (ktfmt was not run).
- `lib/src/buffer_durations.dart` (new): `BufferDurationsMs` and
  `AndroidBufferedVideoPlayerOptions`.
- `lib/video_player_android.dart`: also exports `src/buffer_durations.dart`.
- `lib/src/android_video_player.dart`: `createWithOptions` copies the four
  values onto `CreationOptions` when the options are
  `AndroidBufferedVideoPlayerOptions`.
- `android/src/main/java/io/flutter/plugins/videoplayer/PlezyLoadControl.java`
  (new): copies the values from a create call (all four or none) and builds
  the one `DefaultLoadControl` for upstream's back buffer and the durations.
- `VideoPlayerOptions.java`: the four fields, `hasBufferDurations()`, and the
  copy constructor copies them.
- `VideoPlayerPlugin.java`: both create calls copy the values onto the
  player's options.
- `texture/TextureVideoPlayer.java`, `platformview/PlatformViewVideoPlayer.java`:
  the inline back-buffer block is replaced by `PlezyLoadControl.build`, which
  keeps upstream's checks (negative throws, zero means none).
- `android/build.gradle.kts`: media3 `1.9.2` -> `1.11.0`, the app's
  `media3Version`. The app's 1.11.0 already won Gradle resolution, and
  `media3-common` 1.11.0 publishes runtime version constraints for every
  media3 module (dash, rtsp and smoothstreaming included), so the APK's media3
  is the same either way; the plugin now also compiles against what it runs on.

Tests:
- `test/android_video_player_test.dart`: four new tests for the option; one
  `// ignore: close_sinks` on an upstream helper (the app's root lints apply
  to `packages/`).
- `android/src/test/.../PlezyLoadControlTest.java` (new), two new tests in
  `TextureVideoPlayerTest.java`, one in `VideoPlayerPluginTest.java`; its two
  upstream `CreationOptions` constructor calls pass the four new nulls.
- `VideoAssetTest.java`: the RTSP test URL's host is `example.com`.

### Refreshing on a Flutter upgrade

1. Take the new upstream version from pub.dev into a scratch directory.
2. Reapply the `pigeons/messages.dart` change and regenerate with the Pigeon
   version the new outputs name (`dart run pigeon --input
   pigeons/messages.dart`); `dart format --page-width 100 lib test`. Keep the
   Kotlin to upstream's layout plus the four fields.
3. Reapply every other `PLEZY DELTA` block and the two new files.
4. Set `exoplayerVersion` in `android/build.gradle.kts` to the app's
   `media3Version`.
5. Update `provenance.json`, this section, and run `flutter test` here,
   `flutter test test/reel/feed_buffer_test.dart` at the root, and
   `./gradlew :video_player_android:testDebugUnitTest` from `android/` (Java 21).
