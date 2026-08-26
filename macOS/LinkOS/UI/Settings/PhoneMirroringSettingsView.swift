import SwiftUI

struct PhoneMirroringSettingsView: View {
    @AppStorage("pm_toolbar_visibility") private var toolbarVisibility = "Auto"
    @AppStorage("pm_privacy_mode") private var privacyMode = "Auto"
    @AppStorage("pm_mirror_resolution") private var mirrorResolution = "1080p"
    @AppStorage("pm_frame_rate") private var frameRate = "60 FPS"
    @AppStorage("pm_latency_mode") private var latencyMode = "Balanced"
    @AppStorage("pm_audio_sync") private var audioSync = false
    @AppStorage("pm_dev_stats") private var devStats = false

    var body: some View {
        Form {
            Section("Display") {
                Picker("Toolbar", selection: $toolbarVisibility) {
                    Text("Always").tag("Always")
                    Text("Auto-hide").tag("Auto")
                    Text("Hidden").tag("Hidden")
                }
                
                Picker("Privacy Mode", selection: $privacyMode) {
                    Text("Auto (Dim on control)").tag("Auto")
                    Text("Always").tag("Always")
                    Text("Never").tag("Never")
                }
            }
            
            Section("Streaming Quality") {
                Picker("Resolution", selection: $mirrorResolution) {
                    Text("720p").tag("720p")
                    Text("1080p").tag("1080p")
                    Text("1440p").tag("1440p")
                    Text("Native").tag("Native")
                }
                
                Picker("Frame Rate", selection: $frameRate) {
                    Text("30 FPS").tag("30 FPS")
                    Text("45 FPS").tag("45 FPS")
                    Text("60 FPS").tag("60 FPS")
                    Text("Adaptive").tag("Adaptive")
                }
                
                Picker("Latency Mode", selection: $latencyMode) {
                    Text("Low Latency").tag("Low")
                    Text("Balanced").tag("Balanced")
                    Text("High Quality").tag("High")
                }
            }
            
            Section("Audio & Input") {
                Toggle("Mirror Device Audio", isOn: $audioSync)
            }
            
            Section("Advanced") {
                Toggle("Show Developer Statistics HUD", isOn: $devStats)
            }
        }
        .padding(20)
    }
}
