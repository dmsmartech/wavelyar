import SwiftUI

struct WavelyButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    var style: WavelyButtonStyle = .primary

    enum WavelyButtonStyle { case primary, secondary, ghost }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(background)
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(borderColor, lineWidth: style == .ghost ? 1 : 0)
            )
            .shadow(color: style == .primary ? Color("AccentStart").opacity(0.4) : .clear,
                    radius: 16, y: 6)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            LinearGradient(colors: [Color("AccentStart"), Color("AccentEnd")],
                           startPoint: .leading, endPoint: .trailing)
        case .secondary:
            Color.white.opacity(0.12)
        case .ghost:
            Color.clear
        }
    }

    private var foreground: Color {
        switch style {
        case .primary, .secondary: return .white
        case .ghost: return Color("AccentStart")
        }
    }

    private var borderColor: Color {
        style == .ghost ? Color("AccentStart").opacity(0.5) : .clear
    }
}
