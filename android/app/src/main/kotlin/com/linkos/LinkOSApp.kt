package com.linkos

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

/**
 * LinkOS Application class.
 * Initializes Hilt dependency injection and global services.
 */
@HiltAndroidApp
class LinkOSApp : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    companion object {
        lateinit var instance: LinkOSApp
            private set
    }
}
