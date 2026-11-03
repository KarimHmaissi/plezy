package com.edde746.plezy.cast

import android.content.Context
import com.edde746.plezy.PlezyActivity
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.CastMediaOptions
import com.google.android.gms.cast.framework.media.NotificationOptions

/**
 * Fork: Google Cast configuration, named by the OPTIONS_PROVIDER_CLASS_NAME meta-data in the
 * manifest. Casts to Google's Default Media Receiver, which every Chromecast, Cast-enabled TV and
 * the Shield ship with, so nothing has to be installed on the receiver. The Cast framework's own
 * media notification and lock-screen controls cover what is casting; tapping them opens Plezy.
 */
class CastOptionsProvider : OptionsProvider {
  override fun getCastOptions(context: Context): CastOptions {
    val notification = NotificationOptions.Builder()
      .setTargetActivityClassName(PlezyActivity::class.java.name)
      .build()
    val media = CastMediaOptions.Builder()
      .setNotificationOptions(notification)
      .build()
    return CastOptions.Builder()
      .setReceiverApplicationId(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
      .setCastMediaOptions(media)
      .setResumeSavedSession(true)
      .build()
  }

  override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}
