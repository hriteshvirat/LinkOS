import SwiftUI

struct PhoneMirroringRootView: View {
    @StateObject private var sessionManager = PhoneSessionManager.shared
    
    var body: some View {
        PhoneMirroringView(session: sessionManager.activeSession)
    }
}
