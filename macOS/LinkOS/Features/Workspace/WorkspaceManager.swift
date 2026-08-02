import Foundation
import AppKit

struct WorkspaceProfile: Codable, Identifiable {
    let id: String
    let name: String
    let iconName: String
    let description: String
    let appsToLaunch: [String]
    let urlsToOpen: [String]
    let enableFocusMode: Bool
}

final class WorkspaceManager {
    
    func getProfiles() -> [WorkspaceProfile] {
        [
            WorkspaceProfile(
                id: "dev",
                name: "Developer Workspace",
                iconName: "hammer.fill",
                description: "Launches Cursor, Terminal & Docker",
                appsToLaunch: ["Cursor", "Terminal"],
                urlsToOpen: ["https://github.com"],
                enableFocusMode: true
            ),
            WorkspaceProfile(
                id: "design",
                name: "Design Studio",
                iconName: "paintpalette.fill",
                description: "Launches Figma & Photoshop",
                appsToLaunch: ["Figma", "Photoshop"],
                urlsToOpen: [],
                enableFocusMode: false
            ),
            WorkspaceProfile(
                id: "focus",
                name: "Deep Focus",
                iconName: "moon.fill",
                description: "Enables Do Not Disturb & opens Notes",
                appsToLaunch: ["Notes"],
                urlsToOpen: [],
                enableFocusMode: true
            )
        ]
    }
    
    func launchWorkspace(id: String) {
        guard let profile = getProfiles().first(where: { $0.id == id }) else { return }
        
        for app in profile.appsToLaunch {
            NSWorkspace.shared.launchApplication(app)
        }
        
        for urlStr in profile.urlsToOpen {
            if let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
        }
        
        if profile.enableFocusMode {
            let script = NSAppleScript(source: "tell application \"System Events\" to set volume with output muted")
            script?.executeAndReturnError(nil)
        }
        LinkOSLogger.shared.info("Launched workspace '\(profile.name)'", category: .app)
    }
}

