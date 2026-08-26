import SwiftUI

struct CallIntegrationOverlay: View {
    @ObservedObject var session: PhoneSession
    
    var body: some View {
        Group {
            if session.callState == "RINGING" {
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("📞 Incoming Call")
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(.white)
                            Text(session.incomingCallNumber)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        HStack(spacing: 12) {
                            Button(action: { Task { await session.rejectCall() } }) {
                                Image(systemName: "phone.down.fill")
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.red)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Button(action: { Task { await session.acceptCall() } }) {
                                Image(systemName: "phone.fill")
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.green)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .padding()
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: session.callState)
                .zIndex(100)
            } else if session.callState == "OFFHOOK" {
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("📞 Active Call")
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(.green)
                            Text(session.incomingCallNumber)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        HStack(spacing: 12) {
                            Button(action: { Task { await session.transferCallToHandset() } }) {
                                Image(systemName: "phone.arrow.up.right")
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Transfer Call to Phone")
                            
                            Button(action: { Task { await session.endCall() } }) {
                                Image(systemName: "phone.down.fill")
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.red)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Hang Up")
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .padding()
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: session.callState)
                .zIndex(100)
            }
        }
    }
}
