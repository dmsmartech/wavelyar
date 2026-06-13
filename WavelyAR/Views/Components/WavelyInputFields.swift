import SwiftUI

struct WavelyTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(keyboardType)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(size: 15))
            .foregroundColor(.white)
            .padding(16)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct WavelySecureField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField(placeholder, text: $text)
            .font(.system(size: 15))
            .foregroundColor(.white)
            .padding(16)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct StatusPill: View {
    let label: String
    let color: Color
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(isConnected ? 0.8 : 0), radius: 4)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

// Identical to Wavely's sheet header: centered title, X top-right, Divider below
struct SheetHeader: View {
    let title: String
    let subtitle: String?
    let onDismiss: () -> Void

    init(_ title: String, subtitle: String? = nil, onDismiss: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                }
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Color.white.opacity(0.06))
        }
    }
}
