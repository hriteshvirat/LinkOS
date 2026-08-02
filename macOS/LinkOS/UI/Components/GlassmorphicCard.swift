import SwiftUI

/// Glassmorphic card component — frosted glass effect with subtle border, shadow, and optional glow.
/// Matches the LinkOS premium dark-mode design system across platforms.
struct GlassmorphicCard<Content: View>: View {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let glowColor: Color?
    @ViewBuilder let content: () -> Content
    
    init(
        cornerRadius: CGFloat = 16,
        padding: CGFloat = 16,
        glowColor: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.glowColor = glowColor
        self.content = content
    }
    
    var body: some View {
        content()
            .padding(padding)
            .background(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.45),
                        Color.black.opacity(0.25)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                (glowColor ?? Color.blue).opacity(0.4),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: (glowColor ?? Color.blue).opacity(glowColor != nil ? 0.2 : 0.05), radius: 12, x: 0, y: 4)
    }
}

/// Status indicator dot with optional pulse animation.
struct StatusIndicator: View {
    let isActive: Bool
    let activeColor: Color
    let size: CGFloat
    
    @State private var isPulsing = false
    
    init(isActive: Bool, activeColor: Color = .green, size: CGFloat = 8) {
        self.isActive = isActive
        self.activeColor = activeColor
        self.size = size
    }
    
    var body: some View {
        ZStack {
            if isActive {
                Circle()
                    .fill(activeColor.opacity(0.4))
                    .frame(width: size * 1.8, height: size * 1.8)
                    .scaleEffect(isPulsing ? 1.3 : 1.0)
                    .opacity(isPulsing ? 0.2 : 0.6)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                            isPulsing = true
                        }
                    }
            }
            Circle()
                .fill(isActive ? activeColor : .gray.opacity(0.4))
                .frame(width: size, height: size)
                .shadow(color: isActive ? activeColor.opacity(0.6) : .clear, radius: size / 2)
        }
    }
}

/// Animated connection quality indicator.
struct ConnectionQualityView: View {
    let quality: ConnectionQualityLevel
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(for: index))
                    .frame(width: 4, height: CGFloat(6 + index * 3))
            }
        }
    }
    
    private func barColor(for index: Int) -> Color {
        let activeCount: Int = switch quality {
        case .excellent: 4
        case .good: 3
        case .fair: 2
        case .poor: 1
        case .disconnected: 0
        }
        return index < activeCount ? quality.color : .gray.opacity(0.2)
    }
}
