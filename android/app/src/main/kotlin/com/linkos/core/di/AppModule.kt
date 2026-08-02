package com.linkos.core.di

import android.content.Context
import com.linkos.core.device.DeviceInfoProvider
import com.linkos.core.network.BonjourClient
import com.linkos.core.network.WebSocketClient
import com.linkos.core.plugin.PluginManager
import com.linkos.core.security.BiometricAuth
import com.linkos.core.security.KeystoreManager
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun providePluginManager(): PluginManager {
        return PluginManager()
    }

    @Provides
    @Singleton
    fun provideBonjourClient(@ApplicationContext context: Context): BonjourClient {
        return BonjourClient(context)
    }

    @Provides
    @Singleton
    fun provideWebSocketClient(deviceInfoProvider: DeviceInfoProvider, keystoreManager: KeystoreManager, @ApplicationContext context: Context): WebSocketClient {
        return WebSocketClient(deviceInfoProvider, keystoreManager, context)
    }

    @Provides
    @Singleton
    fun provideKeystoreManager(@ApplicationContext context: Context): KeystoreManager {
        return KeystoreManager(context)
    }

    @Provides
    @Singleton
    fun provideInviteListener(webSocketClient: com.linkos.core.network.WebSocketClient): com.linkos.core.network.InviteListener {
        return com.linkos.core.network.InviteListener(webSocketClient)
    }

    @Provides
    @Singleton
    fun provideBiometricAuth(): BiometricAuth {
        return BiometricAuth()
    }
}
