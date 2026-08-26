import SwiftUI

struct PhoneWaitingUI: View {
    @ObservedObject var session: PhoneSession
    @State private var timeRemaining = 10
    @State private var timer: Timer? = nil
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.8))
                
            VStack(spacing: 4) {
                Text(session.diagnosticsTimeoutReached ? "Connection Failed" : "Connecting to Android...")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                if !session.diagnosticsTimeoutReached {
                    Text("\(timeRemaining)s remaining")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }
            
            VStack(alignment: .leading, spacing: 16) {
                WaitingRow(title: "Connection", status: session.connectionStatus)
                WaitingRow(title: "Permissions", status: session.mediaProjectionStatus)
                WaitingRow(title: "Screen Capture", status: session.frameCaptureStatus)
                WaitingRow(title: encoderTitle, status: session.encoderStatus)
                WaitingRow(title: decoderTitle, status: aggregateDecoderStatus)
                WaitingRow(title: "Rendering", status: session.rendererStatus)
            }
            .padding(24)
            .background(Color.white.opacity(0.05))
            .cornerRadius(16)
            .frame(maxWidth: 350)
            .padding(.horizontal, 24)
            
            if !session.lastErrorMessage.isEmpty {
                Text("Error: \(session.lastErrorMessage)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            if session.diagnosticsTimeoutReached {
                Button(action: { PhoneWindowController.forceRetry() }) {
                    Text("Retry Connection")
                        .fontWeight(.semibold)
                        .foregroundColor(.black)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 10)
            }
        }
        .padding(.vertical, 40)
        .background(Color.black.opacity(0.95))
        .onAppear {
            startCountdown()
        }
        .onDisappear {
            timer?.invalidate()
        }
        .onChange(of: session.rendererStatus) { _ in
            if session.rendererStatus == .success {
                timer?.invalidate()
            }
        }
        .onChange(of: session.diagnosticsTimeoutReached) { reached in
            if !reached {
                startCountdown()
            }
        }
    }
    
    private var encoderTitle: String {
        switch session.encoderStatus {
        case .inProgress(let msg): return msg
        case .success: return "Encoder Running"
        case .failure: return "Encoder Failed"
        case .pending: return "Encoder Starting..."
        }
    }
    
    private var decoderTitle: String {
        switch session.decoderStatus {
        case .success: return "Decoder Running"
        case .inProgress(let msg): return msg
        case .failure: return "Decoder Failed"
        case .pending: return "Decoder Initialization"
        }
    }
    
    private var aggregateDecoderStatus: DiagnosticStageStatus {
        return session.decoderStatus
    }
    
    private func startCountdown() {
        timeRemaining = 10
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if self.timeRemaining > 0 {
                    self.timeRemaining -= 1
                } else {
                    self.timer?.invalidate()
                    if self.session.rendererStatus != .success {
                        self.session.diagnosticsTimeoutReached = true
                    }
                }
            }
        }
    }
}

struct WaitingRow: View {
    let title: String
    let status: DiagnosticStageStatus
    
    var body: some View {
        HStack(spacing: 12) {
            switch status {
            case .pending:
                Image(systemName: "circle")
                    .foregroundColor(.gray.opacity(0.5))
                    .frame(width: 20)
                Text(title)
                    .foregroundColor(.gray.opacity(0.7))
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .frame(width: 20)
                Text(title)
                    .foregroundColor(.white)
            case .failure(_):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .frame(width: 20)
                Text(title)
                    .foregroundColor(.red)
            case .inProgress(_):
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                    .scaleEffect(0.6)
                    .frame(width: 20)
                Text(title)
                    .foregroundColor(.orange)
            }
            Spacer()
        }
        .font(.system(.body, design: .rounded))
    }
}
