package com.edde746.plezy

import android.content.ComponentCallbacks2

/**
 * Where an `onTrimMemory` level goes. Every level is also sent to Dart's
 * MemoryTrimPolicy over `com.plezy/memory_trim`.
 *
 * FlutterActivity's delegate turns every level from RUNNING_LOW up into a
 * memory-pressure message, and the framework answers that by wiping the image
 * cache. UI_HIDDEN (20) is one of those levels, and it arrives on every Back
 * to the launcher, so with Plezy staying warm it would empty the artwork the
 * warm return needs. That level skips `super` (only the renderer hears it)
 * and Dart halves the caches instead. BACKGROUND and up, and the RUNNING_*
 * levels, still go to `super`, whose pressure message now halves too.
 */
internal object TrimMemoryRouting {
  fun reachesFlutterDelegate(level: Int): Boolean = level != ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN
}
