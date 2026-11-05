package com.edde746.plezy

import android.content.ComponentCallbacks2
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrimMemoryRoutingTest {

  @Test
  fun uiHiddenSkipsFlutterActivityAndItsImageCacheWipe() {
    assertFalse(TrimMemoryRouting.reachesFlutterDelegate(ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN))
  }

  @Suppress("DEPRECATION")
  @Test
  fun backgroundAndRunningLevelsStillReachSuper() {
    listOf(
      ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE,
      ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW,
      ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL,
      ComponentCallbacks2.TRIM_MEMORY_BACKGROUND,
      ComponentCallbacks2.TRIM_MEMORY_MODERATE,
      ComponentCallbacks2.TRIM_MEMORY_COMPLETE
    ).forEach { level -> assertTrue("level $level", TrimMemoryRouting.reachesFlutterDelegate(level)) }
  }
}
