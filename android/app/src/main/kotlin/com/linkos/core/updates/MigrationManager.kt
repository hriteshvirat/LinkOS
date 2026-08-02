package com.linkos.core.updates

import android.content.Context
import com.linkos.core.logging.LinkOSLogger
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class MigrationManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val prefs = context.getSharedPreferences("linkos_migrations", Context.MODE_PRIVATE)
    private val currentVersion = 1

    fun migrateIfNeeded() {
        val lastVersion = prefs.getInt("schema_version", 0)
        if (lastVersion < currentVersion) {
            LinkOSLogger.info("Migrating Android app schema from v$lastVersion to v$currentVersion", "Updates")
            prefs.edit().putInt("schema_version", currentVersion).apply()
        }
    }
}
