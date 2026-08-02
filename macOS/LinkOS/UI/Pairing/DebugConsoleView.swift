import SwiftUI
import UniformTypeIdentifiers

/// New polished System Diagnostics / Developer Console View.
/// Displays structured, clean feature-level events or full packet traces dynamically.
struct DebugConsoleView: View {
    @ObservedObject var appState = AppState.shared
    @AppStorage("developerLogMode") private var logMode: String = "Features Only"
    @State private var logEntries: [LogEntry] = []
    @State private var timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    var filteredLogs: [LogEntry] {
        let allLogs = LinkOSLogger.shared.getBuffer()
        if logMode == "Full System" {
            return allLogs
        } else {
            return allLogs.filter { shouldShowInFeaturesOnly($0) }
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header Info Bar
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SYSTEM DETAILS")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                    
                    Text("Mac Name: \(DeviceIdentity.deviceName)")
                    Text("Listening Port: 52637")
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("CONNECTION STATUS")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                    
                    Text("State: \(appState.pairingState.rawValue.uppercased())")
                    Text("Connected Device ID: \(appState.activeSession?.id ?? "None")")
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            // Log Mode Segmented Selector
            HStack {
                Text("Log Mode:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Picker("", selection: $logMode) {
                    Text("Features Only").tag("Features Only")
                    Text("Full System (Verbose)").tag("Full System")
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                
                Spacer()
            }
            .padding(.horizontal)
            
            // Scrollable Console logs
            VStack(alignment: .leading, spacing: 6) {
                Text("SYSTEM LOG OUTPUT")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(filteredLogs.indices, id: \.self) { index in
                                let log = filteredLogs[index]
                                logRow(log)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(Color.black)
                    .cornerRadius(6)
                    .onChange(of: filteredLogs.count) { _, _ in
                        if let lastIndex = filteredLogs.indices.last {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal)
            
            // Buttons Bar
            HStack(spacing: 12) {
                Button("Copy Logs") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.declareTypes([.string], owner: nil)
                    pasteboard.setString(generateLogText(), forType: .string)
                }
                
                Button("Save Logs") {
                    saveLogFile()
                }
                
                Button("Clear Logs") {
                    LinkOSLogger.shared.clearBuffer()
                    logEntries = []
                }
                
                Spacer()
                
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .padding()
        .frame(width: 700, height: 600)
        .onReceive(timer) { _ in
            logEntries = filteredLogs
        }
        .onAppear {
            logEntries = filteredLogs
        }
    }
    
    private func logRow(_ log: LogEntry) -> some View {
        LogRowView(log: log, categoryColor: categoryColor(log.category))
    }
    
    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "Input": return .cyan
        case "Clipboard": return .purple
        case "Media": return .blue
        case "Files": return .orange
        case "Security": return .yellow
        case "Error", "Critical": return .red
        default: return .green
        }
    }
    
    private func shouldShowInFeaturesOnly(_ entry: LogEntry) -> Bool {
        let msg = entry.message
        let cat = entry.category
        
        // Exclude verbose protocol internals, raw WebSocket frames, transport logs, pairing stages, etc.
        if msg.contains("[RAW FRAME") || msg.contains("[TRANSPORT]") || msg.contains("[STAGE ") || msg.contains("STAGE ") || msg.contains("JSON PARSE") || msg.contains("UTF8 SUCCESS") || msg.contains("mDNS") {
            return false
        }
        
        switch cat {
        case "Input":
            return msg.contains("[Trackpad]") || msg.contains("[INPUT]") || msg.contains("TrackpadPlugin")
        case "Clipboard":
            return msg.contains("[Clipboard]") || msg.contains("ClipboardPlugin")
        case "Media":
            return msg.contains("[RemoteDesktop]") || msg.contains("RemoteDesktopPlugin") || msg.contains("ScreenCaptureService")
        case "Files":
            return msg.contains("[Files]") || msg.contains("FileSystemPlugin")
        case "Security":
            return msg.contains("[PermissionManager Status Update]") || msg.contains("PermissionManager")
        case "App", "Network":
            return msg.contains("Connected") || msg.contains("Disconnected") || msg.contains("activated") || msg.contains("deactivated")
        default:
            return false
        }
    }
    
    private func generateLogText() -> String {
        var sb = ""
        sb += "========================\n"
        sb += "LINKOS SYSTEM DIAGNOSTICS REPORT\n"
        sb += "========================\n\n"
        sb += "Log Mode: \(logMode)\n"
        sb += "Mac Name: \(Host.current().localizedName ?? "Mac")\n"
        sb += "OS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        for log in filteredLogs {
            sb += "\(formatter.string(from: log.timestamp)) [\(log.category)] \(log.message)\n"
        }
        return sb
    }
    
    private func saveLogFile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.text]
        savePanel.nameFieldStringValue = "system_diagnostics_log.txt"
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? generateLogText().write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

struct LogRowView: View {
    let log: LogEntry
    let categoryColor: Color
    
    var body: some View {
        let formatter = DateFormatter()
        let _ = formatter.dateFormat = "HH:mm:ss.SSS"
        let timeStr = formatter.string(from: log.timestamp)
        
        return HStack(alignment: .top, spacing: 6) {
            Text(timeStr)
                .foregroundColor(.gray)
                .font(.system(.body, design: .monospaced))
            Text("[\(log.category)]")
                .foregroundColor(categoryColor)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.bold)
            Text(log.message)
                .foregroundColor(.white)
                .font(.system(.body, design: .monospaced))
        }
    }
}
