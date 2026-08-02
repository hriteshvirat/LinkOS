package com.linkos.ui.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.linkos.features.ai.AIAgentScreen
import com.linkos.features.clipboard.ClipboardScreen
import com.linkos.features.dashboard.DashboardScreen
import com.linkos.features.devmode.DevModeScreen
import com.linkos.features.files.FileBrowserScreen
import com.linkos.features.home.HomeScreen
import com.linkos.features.media.MediaControlScreen
import com.linkos.features.nfc.NFCScreen
import com.linkos.features.notifications.NotificationsScreen
import com.linkos.features.remotedesktop.RemoteDesktopScreen
import com.linkos.features.streamdeck.StreamDeckScreen
import com.linkos.features.terminal.TerminalScreen
import com.linkos.features.trackpad.TrackpadScreen
import com.linkos.features.workspace.TabletScreen
import com.linkos.features.workspace.WorkspaceScreen
import com.linkos.features.camera.CameraScreen

import com.linkos.core.device.DeviceInfoProvider
import com.linkos.features.onboarding.OnboardingScreen
import com.linkos.features.workspace.AppLauncherScreen
import com.linkos.features.workspace.DeviceDashboardScreen
import com.linkos.features.ai.AIProviderConfigScreen
import com.linkos.features.ai.CustomCommandsScreen
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue

@Composable
fun LinkOSNavHost(
    navController: NavHostController = rememberNavController(),
    deviceInfoProvider: DeviceInfoProvider
) {
    var onboardingCompleted by remember { mutableStateOf(deviceInfoProvider.isOnboardingCompleted()) }

    if (!onboardingCompleted) {
        OnboardingScreen(
            onComplete = { name ->
                deviceInfoProvider.updateDeviceName(name)
                deviceInfoProvider.setOnboardingCompleted(true)
                onboardingCompleted = true
            }
        )
    } else {
        NavHost(
            navController = navController,
            startDestination = "home"
        ) {
        composable("home") {
            HomeScreen(
                onNavigateToFeature = { route ->
                    navController.navigate(route)
                }
            )
        }
        composable("trackpad") {
            TrackpadScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("remote_desktop") {
            RemoteDesktopScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("clipboard") {
            ClipboardScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("dashboard") {
            DashboardScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("notifications") {
            NotificationsScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("files") {
            FileBrowserScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("terminal") {
            TerminalScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("ai_agent") {
            AIAgentScreen(
                onNavigateBack = { navController.popBackStack() },
                onNavigateToProviderConfig = { navController.navigate("ai_provider_config") },
                onNavigateToCustomCommands = { navController.navigate("ai_custom_commands") }
            )
        }
        composable("ai_provider_config") {
            AIProviderConfigScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("ai_custom_commands") {
            CustomCommandsScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("streamdeck") {
            StreamDeckScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("workspace") {
            WorkspaceScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("devmode") {
            DevModeScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("media") {
            MediaControlScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("nfc") {
            NFCScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("tablet") {
            TabletScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("app_launcher") {
            AppLauncherScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("device_dashboard") {
            DeviceDashboardScreen(onNavigateBack = { navController.popBackStack() })
        }
        composable("camera") {
            CameraScreen(onNavigateBack = { navController.popBackStack() })
        }
    }
    }
}
