import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentStep = 0
    @State private var deviceName = ""
    @State private var deviceCustomName = ""
    @State private var selectedAvatar = "💻"
    
    // Timer for checking permissions automatically in step 3
    @State private var permissionTimer: Timer? = nil
    
    @ObservedObject var permissionManager = PermissionManager.shared
    
    let avatars = ["💻", "📱", "🦊", "🚀", "💡", "🎨", "🛠", "🔑", "🍿", "🎮", "🏎", "👾"]
    
    var body: some View {
        ZStack {
            // Sleek Dark background with mesh gradient highlights
            Color(hex: "0B0F19").ignoresSafeArea()
            
            // Decorative background glowing nodes
            Circle()
                .fill(Color(hex: "4F46E5").opacity(0.15))
                .frame(width: 350, height: 350)
                .blur(radius: 80)
                .offset(x: -200, y: -150)
            
            Circle()
                .fill(Color(hex: "06B6D4").opacity(0.12))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: 200, y: 150)
            
            VStack(spacing: 24) {
                // Main Glass Card
                VStack(spacing: 0) {
                    // Title Bar (Clean title with no close actions)
                    HStack {
                        Image(systemName: "circle.grid.3x3.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(LinearGradient(colors: [Color(hex: "6366F1"), Color(hex: "06B6D4")], startPoint: .leading, endPoint: .trailing))
                        Text("LinkOS Companion")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.gray)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.02))
                    
                    Divider().opacity(0.1)
                    
                    // Step Content View Hierarchy
                    ZStack {
                        switch currentStep {
                        case 0:
                            welcomeStep
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                        case 1:
                            identityStep
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                        case 2:
                            permissionsStep
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                        default:
                            finishStep
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                        }
                    }
                    .frame(height: 380)
                    .padding(30)
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
                .shadow(color: Color.black.opacity(0.4), radius: 30, x: 0, y: 20)
                .frame(width: 580)
                
                // Pagination Indicator
                HStack(spacing: 8) {
                    ForEach(0..<4) { index in
                        Circle()
                            .fill(currentStep == index ? Color(hex: "6366F1") : Color.white.opacity(0.15))
                            .frame(width: 6, height: 6)
                            .animation(.spring(), value: currentStep)
                    }
                }
            }
        }
        .onAppear {
            deviceName = appState.profileName
            selectedAvatar = appState.profileAvatar
            deviceCustomName = appState.customDeviceName
        }
        .onDisappear {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }
    
    // MARK: - Welcome Step
    
    private var welcomeStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: "6366F1").opacity(0.2), Color(hex: "3B82F6").opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 80, height: 80)
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: "818CF8"), Color(hex: "34D399")], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            
            VStack(spacing: 8) {
                Text("Welcome to LinkOS")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Text("Your seamless macOS & Android ecosystem link.\nControl cursor, share files, sync clipboard, and automate actions.")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            
            Spacer()
            
            actionButton(title: "Get Started") {
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentStep = 1
                }
            }
        }
    }
    
    // MARK: - Identity Step (Name & Avatar Selection)
    
    private var identityStep: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Configure Identity")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("How you'll be represented across connected devices.")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Name Fields
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROFILE NAME")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "6366F1"))
                    TextField("Hritesh", text: $deviceName)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        .foregroundStyle(.white)
                        .font(.system(size: 13))
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("MAC DEVICE NAME")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "34D399"))
                    TextField("My Mac", text: $deviceCustomName)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        .foregroundStyle(.white)
                        .font(.system(size: 13))
                }
            }
            
            // Avatar Selector Grid
            VStack(alignment: .leading, spacing: 8) {
                Text("SELECT AVATAR")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "06B6D4"))
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                    ForEach(avatars, id: \.self) { avatar in
                        Text(avatar)
                            .font(.system(size: 24))
                            .frame(width: 44, height: 44)
                            .background(selectedAvatar == avatar ? Color(hex: "6366F1").opacity(0.2) : Color.white.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selectedAvatar == avatar ? Color(hex: "6366F1") : Color.white.opacity(0.1), lineWidth: 1.5)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedAvatar = avatar
                            }
                    }
                }
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                secondaryButton(title: "Back") {
                    withAnimation { currentStep = 0 }
                }
                actionButton(title: "Next") {
                    appState.profileName = deviceName.isEmpty ? "Mac User" : deviceName
                    appState.profileAvatar = selectedAvatar
                    appState.customDeviceName = deviceCustomName.isEmpty ? "Mac" : deviceCustomName
                    
                    // Start checking permissions automatically on moving to step 2
                    startPermissionPolling()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentStep = 2
                    }
                }
            }
        }
    }
    
    // MARK: - Permissions Step
    
    private var permissionsStep: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Grant System Permissions")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("LinkOS requires accessibility and screen capture to control inputs and stream screen.")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                // Accessibility Check card
                permissionCard(
                    title: "Accessibility API",
                    description: "Allows cursor control & trackpad coordinate injection.",
                    isGranted: permissionManager.isAccessibilityGranted,
                    action: { permissionManager.requestPermissionExplicitly(.accessibility) }
                )
                
                // Screen Recording Check card
                permissionCard(
                    title: "Screen Recording",
                    description: "Allows capturing system frame buffer for remote desktop.",
                    isGranted: permissionManager.hasPermission(.screenRecording),
                    action: { permissionManager.requestPermissionExplicitly(.screenRecording) }
                )
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                secondaryButton(title: "Back") {
                    permissionTimer?.invalidate()
                    permissionTimer = nil
                    withAnimation { currentStep = 1 }
                }
                actionButton(title: "Next") {
                    permissionTimer?.invalidate()
                    permissionTimer = nil
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentStep = 3
                    }
                }
            }
        }
    }
    
    // MARK: - Finish Step
    
    private var finishStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color(hex: "10B981").opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Color(hex: "10B981"))
            }
            
            VStack(spacing: 8) {
                Text("Setup Completed!")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("Welcome to the ecosystem! LinkOS is running and active in the background. You can open dashboard at any time.")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            
            Spacer()
            
            actionButton(title: "Launch LinkOS Dashboard") {
                withAnimation(.easeInOut(duration: 0.4)) {
                    appState.hasCompletedOnboarding = true
                }
            }
        }
    }
    
    // MARK: - Helper UI Builders
    
    private func permissionCard(title: String, description: String, isGranted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            }
            Spacer()
            
            if isGranted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(hex: "10B981"))
                    Text("Granted")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "10B981"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(hex: "10B981").opacity(0.1))
                .cornerRadius(6)
            } else {
                Button(action: action) {
                    Text("Grant")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color(hex: "6366F1"))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.02))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.05), lineWidth: 1))
    }
    
    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(colors: [Color(hex: "6366F1"), Color(hex: "4F46E5")], startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(8)
                .shadow(color: Color(hex: "6366F1").opacity(0.3), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(.plain)
    }
    
    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    
    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                PermissionManager.shared.checkPermissionsSilentlyOnLaunch()
            }
        }
    }
}
