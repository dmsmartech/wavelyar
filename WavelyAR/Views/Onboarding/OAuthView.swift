import SwiftUI

struct OAuthView: View {
    let instance: HADiscoveredInstance
    @ObservedObject private var oauth = HAOAuthService.shared
    @ObservedObject private var appState = AppState.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color("Background").ignoresSafeArea()

            VStack(spacing: 0) {
                SheetHeader("Accedi a Home Assistant", onDismiss: { dismiss() })

                Spacer()

                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color("AccentStart"), Color("AccentEnd")],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 80, height: 80)
                            .shadow(color: Color("AccentStart").opacity(0.5), radius: 30)
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                    }

                    VStack(spacing: 8) {
                        Text(instance.name)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(instance.displayAddress)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(Color("AccentStart"))
                        Text("Verrai reindirizzato alla pagina di login di Home Assistant per autorizzare Wavely AR.")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(.red.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    if isLoading {
                        HStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("Autenticazione in corso...")
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        WavelyButton(title: "Accedi con Home Assistant",
                                     icon: "lock.open.fill",
                                     action: startLogin)
                        WavelyButton(title: "Annulla", icon: nil, action: { dismiss() },
                                     style: .secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 48)
            }
        }
    }

    private func startLogin() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await oauth.startOAuthFlow()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isLoading = false
        }
    }
}
