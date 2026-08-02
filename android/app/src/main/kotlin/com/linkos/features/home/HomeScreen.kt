package com.linkos.features.home

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.linkos.core.network.ConnectionState
import com.linkos.core.network.DiscoveredService
import com.linkos.ui.components.HapticUtils
import com.linkos.ui.components.pressScale
import com.linkos.ui.theme.*
import org.json.JSONObject

// ── Color Constants ───────────────────────────────────────────────────
private val BlueprintBackground = Color(0xFF0D0F13)
private val BlueprintCard = Color(0xFF171A21)
private val BlueprintAccentPurple = Color(0xFF6366F1)
private val BlueprintAccentBlue = Color(0xFF3B82F6)
private val BlueprintAccentCyan = Color(0xFF06B6D4)
private val BlueprintTextPrimary = Color(0xFFFFFFFF)
private val BlueprintTextSecondary = Color(0xFFC9CDD4)

// ── Features Definition (Only Fully Implemented Features) ────────────
private data class FeatureBlueprintItem(
    val route: String,
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
    val accentColor: Color
)

private val blueprintFeatures = listOf(
    FeatureBlueprintItem("remote_desktop", "Remote Desktop", "Control your Mac screen", Icons.Default.DesktopWindows, BlueprintAccentBlue),
    FeatureBlueprintItem("trackpad", "Trackpad & Keyboard", "Control trackpad & keyboard", Icons.Default.Mouse, Color(0xFF10B981)),
    FeatureBlueprintItem("files", "File Explorer", "Browse and manage files", Icons.Default.FolderOpen, BlueprintAccentCyan),
    FeatureBlueprintItem("clipboard", "Clipboard", "Sync across devices", Icons.Default.ContentPaste, Color(0xFF8B5CF6)),
    FeatureBlueprintItem("camera", "Camera Continuity", "Use phone as Mac webcam", Icons.Default.Camera, Color(0xFFF59E0B)),
    FeatureBlueprintItem("terminal", "Terminal", "Command line access", Icons.Default.Terminal, Color(0xFF34D399)),
    FeatureBlueprintItem("ai_agent", "AI Agent", "Ask, Automate, Done.", Icons.Default.Psychology, Color(0xFFEC4899)),
    FeatureBlueprintItem("streamdeck", "Shortcuts", "Custom macros & shortcuts", Icons.Default.GridView, Color(0xFFEF4444))
)

// ── Main HomeScreen ─────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    onNavigateToFeature: (String) -> Unit,
    viewModel: HomeViewModel = hiltViewModel()
) {
    val discoveredDevices by viewModel.discoveredDevices.collectAsState()
    val isDiscovering by viewModel.isDiscovering.collectAsState()
    val connectionState by viewModel.connectionState.collectAsState()
    val connectedMacName by viewModel.connectedMacName.collectAsState()
    val showPinCodeToUser by viewModel.showPinCodeToUser.collectAsState()
    val requestPinCodeFromUser by viewModel.requestPinCodeFromUser.collectAsState()
    val hasConnectionFailed by viewModel.hasConnectionFailed.collectAsState()

    val context = LocalContext.current
    var selectedBottomTab by remember { mutableIntStateOf(0) }
    var showManualPinScreen by remember { mutableStateOf(false) }
    var showDebugConsole by remember { mutableStateOf(false) }
    var isPairingFromPinScreen by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        if (!viewModel.isManualDisconnect) {
            viewModel.scanForDevices()
        }
        onDispose { viewModel.stopDiscovery() }
    }

    val isConnected = connectionState == ConnectionState.CONNECTED

    val performQRScan: () -> Unit = {
        // Disconnect any existing session first to ensure a clean slate
        viewModel.disconnect()
        isPairingFromPinScreen = true
        val scanner = GmsBarcodeScanning.getClient(context)
        scanner.startScan()
            .addOnSuccessListener { barcode: Barcode ->
                // Do NOT set showManualPinScreen=false here — let connection state drive
                // dismissal so the PIN screen stays visible during the connect handshake.
                // (Same behaviour as the homescreen scan button which has no UI state reset)
                val rawValue = barcode.rawValue ?: ""
                try {
                    if (rawValue.startsWith("linkos://pair")) {
                        val uri = android.net.Uri.parse(rawValue)
                        val host = uri.getQueryParameter("host")
                        val port = uri.getQueryParameter("port")?.toIntOrNull() ?: 52637
                        val code = uri.getQueryParameter("code")
                        if (host != null) {
                            viewModel.connectToDeviceDirect(host, port, code, "QR")
                        }
                    } else if (rawValue.startsWith("{")) {
                        val json = JSONObject(rawValue)
                        val host = if (json.has("host")) json.getString("host") else null
                        val port = if (json.has("port")) json.getInt("port") else 52637
                        val code = if (json.has("code")) json.getString("code") else null
                        if (host != null) {
                            viewModel.connectToDeviceDirect(host, port, code, "QR")
                        }
                    }
                } catch (_: Exception) {
                    viewModel.connectToDeviceDirect(rawValue, 52637, null, "QR")
                }
            }
            .addOnFailureListener {
                isPairingFromPinScreen = false
            }
            .addOnCanceledListener {
                isPairingFromPinScreen = false
            }
    }

    // Dismiss PIN screen once connected; clear flag when fully disconnected or failed
    LaunchedEffect(connectionState, hasConnectionFailed) {
        if (connectionState == ConnectionState.CONNECTED) {
            showManualPinScreen = false
            isPairingFromPinScreen = false
        }
        if (hasConnectionFailed) {
            isPairingFromPinScreen = false
        }
    }

    Scaffold(
        bottomBar = {
            BlueprintBottomNavigation(
                selectedTab = selectedBottomTab,
                onSelectTab = { index ->
                    HapticUtils.lightTap(context)
                    selectedBottomTab = index
                    if (index == 1) onNavigateToFeature("files")
                    if (index == 2) onNavigateToFeature("clipboard")
                }
            )
        },
        containerColor = BlueprintBackground
    ) { paddingValues ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            when {
                showDebugConsole -> {
                    DebugConsoleView(
                        connectionState = connectionState,
                        lastFailureStage = null,
                        onClose = { showDebugConsole = false }
                    )
                }

                // 1. PIN Entry / Display Flow
                // isPairingFromPinScreen keeps the screen alive during CONNECTING→PAIRING→CONNECTED
                showManualPinScreen || requestPinCodeFromUser || isPairingFromPinScreen -> {
                    PairingPinScreen(
                        pinCodeToDisplay = showPinCodeToUser,
                        onBack = {
                            showManualPinScreen = false
                            isPairingFromPinScreen = false
                            viewModel.disconnect()
                        },
                        onSubmitPin = { code ->
                            if (connectionState == ConnectionState.DISCONNECTED) {
                                val targetDevice = discoveredDevices.firstOrNull()
                                if (targetDevice != null) {
                                    viewModel.connectToDevice(targetDevice, pairingCode = code, method = "PIN")
                                } else {
                                    android.widget.Toast.makeText(context, "No nearby Mac devices discovered yet. Please make sure the Mac app is open.", android.widget.Toast.LENGTH_LONG).show()
                                }
                            } else {
                                viewModel.sendPairingRequest(code)
                            }
                            showManualPinScreen = false
                        },
                        onScanQR = performQRScan
                    )
                }

                // 2. Connected Screen
                isConnected -> {
                    ConnectedHomeScreen(
                        macName = connectedMacName,
                        viewModel = viewModel,
                        onNavigateToFeature = onNavigateToFeature,
                        onDisconnect = { viewModel.disconnectDevice() },
                        onOpenDebugConsole = { showDebugConsole = true }
                    )
                }

                // 3. Features Tab Selected
                selectedBottomTab == 3 -> {
                    FeaturesGridScreen(onNavigateToFeature = onNavigateToFeature)
                }

                // 4. Discover & Pair Screen (Disconnected State)
                else -> {
                    val filteredDevices = if (isConnected) {
                        discoveredDevices.filter { 
                            it.deviceName != connectedMacName && it.host != connectedMacName 
                        }
                    } else {
                        discoveredDevices
                    }

                    DiscoverAndPairScreen(
                        discoveredDevices = filteredDevices,
                        connectedCount = if (isConnected) 1 else 0,
                        isDiscovering = isDiscovering,
                        isManualDisconnect = viewModel.isManualDisconnect,
                        onScanDevices = { viewModel.scanForDevices() },
                        onScanQR = performQRScan,
                        onEnterPinManually = { showManualPinScreen = true },
                        onConnectDevice = { device -> viewModel.connectToDevice(device, method = "PIN") },
                        onResetOnboarding = {
                            val prefs = context.getSharedPreferences("linkos_prefs", android.content.Context.MODE_PRIVATE)
                            prefs.edit().clear().apply()
                            android.widget.Toast.makeText(context, "Onboarding state and custom device name reset! Please restart the app.", android.widget.Toast.LENGTH_LONG).show()
                        },
                        onOpenDebugConsole = { showDebugConsole = true }
                    )
                }
            }
        }
    }
}

// ── 1. Discover & Pair Screen ─────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DiscoverAndPairScreen(
    discoveredDevices: List<DiscoveredService>,
    connectedCount: Int,
    isDiscovering: Boolean,
    isManualDisconnect: Boolean,
    onScanDevices: () -> Unit,
    onScanQR: () -> Unit,
    onEnterPinManually: () -> Unit,
    onConnectDevice: (DiscoveredService) -> Unit,
    onResetOnboarding: () -> Unit,
    onOpenDebugConsole: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Top Bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Image(
                    painter = androidx.compose.ui.res.painterResource(id = com.linkos.R.drawable.ic_linkos_logo),
                    contentDescription = "LinkOS Brand Logo",
                    modifier = Modifier
                        .size(32.dp)
                        .clip(RoundedCornerShape(8.dp))
                )
                Text(
                    text = "LinkOS",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = BlueprintTextPrimary
                )
            }

            IconButton(
                onClick = onOpenDebugConsole,
                colors = IconButtonDefaults.iconButtonColors(contentColor = BlueprintAccentPurple)
            ) {
                Icon(
                    imageVector = Icons.Default.BugReport,
                    contentDescription = "Open Debug Console",
                    modifier = Modifier.size(24.dp)
                )
            }
        }

        // Connected Devices Summary Card
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(BlueprintCard)
                .padding(16.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text(
                        text = "Connected Devices",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        color = BlueprintTextPrimary
                    )
                    Text(
                        text = if (connectedCount == 0) "No active connection" else "$connectedCount device connected",
                        style = MaterialTheme.typography.bodySmall,
                        color = BlueprintTextSecondary
                    )
                }
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(if (connectedCount > 0) StatusConnected.copy(alpha = 0.2f) else Color.White.copy(alpha = 0.05f)),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "$connectedCount",
                        fontWeight = FontWeight.Bold,
                        color = if (connectedCount > 0) StatusConnected else BlueprintTextSecondary
                    )
                }
            }
        }

        // Section Title
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = "Nearby Devices",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = BlueprintTextPrimary
            )
            Text(
                text = "Make sure LinkOS app is running on your Mac",
                style = MaterialTheme.typography.bodySmall,
                color = BlueprintTextSecondary
            )
        }

        // Discovered Devices List or Empty State
        if (discoveredDevices.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(180.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(BlueprintCard)
                    .padding(16.dp),
                contentAlignment = Alignment.Center
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    if (isDiscovering) {
                        CircularProgressIndicator(color = BlueprintAccentPurple, strokeWidth = 2.dp, modifier = Modifier.size(24.dp))
                        Text(
                            text = "Scanning for nearby macOS devices...",
                            color = BlueprintTextSecondary,
                            fontSize = 13.sp,
                            textAlign = TextAlign.Center
                        )
                    } else {
                        if (isManualDisconnect) {
                            Text(
                                text = "Searching is stopped.\nTap \"Scan Again\" to search for nearby macOS devices.",
                                color = BlueprintTextSecondary,
                                fontSize = 13.sp,
                                textAlign = TextAlign.Center
                            )
                            Button(
                                onClick = onScanDevices,
                                shape = RoundedCornerShape(10.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = BlueprintAccentPurple)
                            ) {
                                Text("Scan Again", fontWeight = FontWeight.Bold)
                            }
                        } else {
                            Text(
                                text = "No nearby macOS devices found.",
                                color = BlueprintTextSecondary,
                                fontSize = 13.sp,
                                textAlign = TextAlign.Center
                            )
                            Button(
                                onClick = onScanDevices,
                                shape = RoundedCornerShape(10.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = BlueprintAccentPurple)
                            ) {
                                Text("Scan Again", fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.weight(1f))
        } else {
            Column(modifier = Modifier.weight(1f)) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    if (isDiscovering) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            CircularProgressIndicator(color = BlueprintAccentPurple, strokeWidth = 1.5.dp, modifier = Modifier.size(14.dp))
                            Text("Scanning for nearby macOS devices...", color = BlueprintTextSecondary, fontSize = 12.sp)
                        }
                    } else {
                        Text("Scan complete", color = BlueprintTextSecondary, fontSize = 12.sp)
                        TextButton(
                            onClick = onScanDevices,
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                            colors = ButtonDefaults.textButtonColors(contentColor = BlueprintAccentPurple)
                        ) {
                            Text("Scan Again", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }

                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    items(discoveredDevices, key = { it.host }) { device ->
                        BlueprintDeviceCard(
                            device = device,
                            onPair = { onConnectDevice(device) }
                        )
                    }
                }
            }
        }

        // Bottom CTA Actions
        Column(
            verticalArrangement = Arrangement.spacedBy(10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp)
        ) {
            Button(
                onClick = onScanQR,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp)
                    .pressScale(onClick = {}),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = BlueprintAccentPurple)
            ) {
                Icon(Icons.Default.QrCodeScanner, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(10.dp))
                Text("Scan QR Code", fontSize = 15.sp, fontWeight = FontWeight.Bold)
            }

            TextButton(onClick = onEnterPinManually) {
                Text(
                    text = "Enter PIN Manually",
                    color = BlueprintTextSecondary,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium
                )
            }

            OutlinedButton(
                onClick = onResetOnboarding,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(44.dp),
                shape = RoundedCornerShape(12.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, BlueprintAccentPurple.copy(alpha = 0.5f))
            ) {
                Icon(Icons.Default.Refresh, contentDescription = null, tint = BlueprintAccentPurple, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Reset Onboarding / Device Name", color = BlueprintAccentPurple, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun BlueprintDeviceCard(
    device: DiscoveredService,
    onPair: () -> Unit
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(BlueprintCard)
            .padding(16.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = device.deviceName,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = BlueprintTextPrimary
                )
                Text(
                    text = device.host,
                    style = MaterialTheme.typography.bodySmall,
                    color = BlueprintTextSecondary
                )
            }

            Button(
                onClick = onPair,
                shape = RoundedCornerShape(10.dp),
                colors = ButtonDefaults.buttonColors(containerColor = BlueprintAccentBlue),
                modifier = Modifier.pressScale(onClick = {})
            ) {
                Text("Pair", fontWeight = FontWeight.Bold)
            }
        }
    }
}

// ── 2. Pairing PIN Screen ─────────────────────────────────────────────

@Composable
private fun PairingPinScreen(
    pinCodeToDisplay: String?,
    onBack: () -> Unit,
    onSubmitPin: (String) -> Unit,
    onScanQR: (() -> Unit)? = null
) {
    var pinInput by remember { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        if (pinCodeToDisplay == null) {
            focusRequester.requestFocus()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(24.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = BlueprintTextPrimary)
            }
            Spacer(Modifier.width(12.dp))
            Text(
                text = "Pair with Mac",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = BlueprintTextPrimary
            )
        }

        Spacer(Modifier.height(16.dp))

        if (pinCodeToDisplay != null) {
            Text(
                text = "Enter this PIN on your Mac",
                style = MaterialTheme.typography.titleSmall,
                color = BlueprintTextSecondary
            )
            Text(
                text = pinCodeToDisplay,
                style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.Bold,
                color = BlueprintAccentPurple,
                letterSpacing = 8.sp
            )
        } else {
            Text(
                text = "Enter the 6-digit PIN shown on your Mac screen",
                style = MaterialTheme.typography.titleSmall,
                color = BlueprintTextSecondary,
                textAlign = TextAlign.Center
            )

            val keyboardController = LocalSoftwareKeyboardController.current

            Row(
                modifier = Modifier.clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null
                ) {
                    focusRequester.requestFocus()
                    keyboardController?.show()
                },
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                for (i in 0 until 6) {
                    val char = pinInput.getOrNull(i)?.toString() ?: ""
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(BlueprintCard)
                            .border(1.dp, if (char.isNotEmpty()) BlueprintAccentPurple else Color.Transparent, RoundedCornerShape(10.dp)),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = char,
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Bold,
                            color = BlueprintTextPrimary
                        )
                    }
                }
            }

            OutlinedTextField(
                value = pinInput,
                onValueChange = { input ->
                    if (input.length <= 6 && input.all { it.isDigit() }) {
                        pinInput = input
                        if (input.length == 6) {
                            onSubmitPin(input)
                        }
                    }
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                singleLine = true,
                modifier = Modifier
                    .fillMaxWidth()
                    .alpha(0.01f)
                    .focusRequester(focusRequester)
            )

            if (onScanQR != null) {
                Spacer(Modifier.height(16.dp))
                Button(
                    onClick = onScanQR,
                    modifier = Modifier
                        .fillMaxWidth(0.8f)
                        .height(50.dp)
                        .pressScale(onClick = {}),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = BlueprintAccentPurple)
                ) {
                    Icon(
                        imageVector = Icons.Default.QrCodeScanner,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(Modifier.width(10.dp))
                    Text("Scan QR Code", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

// ── 3. Connected Screen ───────────────────────────────────────────────

@Composable
private fun ConnectedHomeScreen(
    macName: String,
    viewModel: HomeViewModel,
    onNavigateToFeature: (String) -> Unit,
    onDisconnect: () -> Unit,
    onOpenDebugConsole: () -> Unit
) {
    val macBattery by viewModel.macBatteryPercent.collectAsState()
    val isMacCharging by viewModel.isMacCharging.collectAsState()
    val isMacOnACPower by viewModel.isMacOnACPower.collectAsState()
    val androidBattery by viewModel.androidBatteryPercentState.collectAsState()
    val isAndroidCharging by viewModel.isAndroidChargingState.collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        // Top Header Row with logo/title & Debug Console button
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Image(
                    painter = androidx.compose.ui.res.painterResource(id = com.linkos.R.drawable.ic_linkos_logo),
                    contentDescription = "LinkOS Brand Logo",
                    modifier = Modifier
                        .size(24.dp)
                        .clip(RoundedCornerShape(6.dp))
                )
                Text(
                    text = "LinkOS",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = BlueprintTextPrimary
                )
            }

            IconButton(
                onClick = onOpenDebugConsole,
                colors = IconButtonDefaults.iconButtonColors(contentColor = BlueprintAccentPurple)
            ) {
                Icon(
                    imageVector = Icons.Default.BugReport,
                    contentDescription = "Open Debug Console",
                    modifier = Modifier.size(24.dp)
                )
            }
        }

        // Hero Mac Card
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(
                    Brush.linearGradient(
                        colors = listOf(
                            BlueprintCard,
                            Color(0xFF1E2330)
                        )
                    )
                )
                .padding(20.dp)
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(44.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .background(Brush.linearGradient(listOf(BlueprintAccentPurple, BlueprintAccentBlue))),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(Icons.Default.LaptopMac, contentDescription = null, tint = Color.White, modifier = Modifier.size(24.dp))
                        }
                        Column {
                            Text(
                                text = "Active Connection",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = BlueprintTextPrimary
                            )
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(
                                    modifier = Modifier
                                        .size(6.dp)
                                        .clip(CircleShape)
                                        .background(StatusConnected)
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    text = "Connected to $macName",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = StatusConnected,
                                    fontSize = 11.sp
                                )
                            }
                        }
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End
                ) {
                    Button(
                        onClick = onDisconnect,
                        shape = RoundedCornerShape(10.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444).copy(alpha = 0.85f)),
                        modifier = Modifier.height(34.dp)
                    ) {
                        Text(
                            text = "Disconnect",
                            color = Color.White,
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1
                        )
                    }
                }

                HorizontalDivider(color = Color.White.copy(alpha = 0.08f))

                // Battery Metrics Row
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceAround
                ) {
                    HeroMetricItem(
                        label = "Mac Battery",
                        value = "$macBattery%",
                        subtitle = if (isMacCharging && macBattery < 100) "Charging ⚡" else if (isMacOnACPower || macBattery >= 100) "Power Adapter 🔌" else "On Battery 🔋"
                    )
                    HeroMetricItem(
                        label = "Phone Battery",
                        value = "$androidBattery%",
                        subtitle = if (isAndroidCharging) "Charging ⚡" else "On Battery 🔋"
                    )
                }
            }
        }

        // Quick Actions Header
        Text(
            text = "Quick Actions",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = BlueprintTextPrimary
        )

        // Features Grid (Excludes unimplemented features)
        LazyVerticalGrid(
            columns = GridCells.Fixed(3),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.weight(1f)
        ) {
            items(blueprintFeatures) { item ->
                QuickActionTile(item = item, onClick = { onNavigateToFeature(item.route) })
            }
        }
    }
}

@Composable
private fun HeroMetricItem(label: String, value: String, subtitle: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, style = MaterialTheme.typography.bodySmall, color = BlueprintTextSecondary, fontSize = 11.sp)
        Spacer(Modifier.height(2.dp))
        Text(value, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = BlueprintTextPrimary)
        Spacer(Modifier.height(2.dp))
        Text(subtitle, style = MaterialTheme.typography.labelSmall, color = BlueprintTextSecondary, fontSize = 10.sp)
    }
}

@Composable
private fun QuickActionTile(item: FeatureBlueprintItem, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(16.dp))
            .background(BlueprintCard)
            .pressScale(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(item.accentColor.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(item.icon, contentDescription = item.title, tint = item.accentColor, modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = item.title,
                style = MaterialTheme.typography.labelSmall,
                color = BlueprintTextPrimary,
                fontWeight = FontWeight.SemiBold,
                fontSize = 11.sp,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                modifier = Modifier.padding(horizontal = 4.dp)
            )
        }
    }
}

// ── 4. Features Grid Screen ──────────────────────────────────────────

@Composable
private fun FeaturesGridScreen(onNavigateToFeature: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(
            text = "Features",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            color = BlueprintTextPrimary
        )

        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxSize()
        ) {
            items(blueprintFeatures) { item ->
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(BlueprintCard)
                        .pressScale { onNavigateToFeature(item.route) }
                        .padding(16.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(item.accentColor.copy(alpha = 0.18f)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(item.icon, contentDescription = null, tint = item.accentColor, modifier = Modifier.size(20.dp))
                        }
                        Column {
                            Text(item.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = BlueprintTextPrimary)
                            Text(item.subtitle, style = MaterialTheme.typography.bodySmall, color = BlueprintTextSecondary, fontSize = 10.sp)
                        }
                    }
                }
            }
        }
    }
}

// ── Bottom Navigation Bar ─────────────────────────────────────────────

@Composable
private fun BlueprintBottomNavigation(
    selectedTab: Int,
    onSelectTab: (Int) -> Unit
) {
    NavigationBar(
        containerColor = BlueprintCard,
        tonalElevation = 0.dp
    ) {
        val tabs = listOf(
            Triple(0, "Home", Icons.Default.Home),
            Triple(1, "File Explorer", Icons.Default.FolderOpen),
            Triple(2, "Clipboard", Icons.Default.ContentPaste),
            Triple(3, "Features", Icons.Default.GridView)
        )

        tabs.forEach { (index, label, icon) ->
            val isSelected = selectedTab == index
            NavigationBarItem(
                selected = isSelected,
                onClick = { onSelectTab(index) },
                icon = { Icon(icon, contentDescription = label) },
                label = { Text(label, fontSize = 11.sp, fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium) },
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = Color.White,
                    selectedTextColor = BlueprintAccentPurple,
                    indicatorColor = BlueprintAccentPurple,
                    unselectedIconColor = BlueprintTextSecondary,
                    unselectedTextColor = BlueprintTextSecondary
                )
            )
        }
    }
}
