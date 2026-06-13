import SwiftUI

struct SettingsView: View {
    @ObservedObject private var oauth = HAOAuthService.shared
    @ObservedObject private var wsService = HAWebSocketService.shared
    @Environment(\.dismiss) private var dismiss

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        ZStack {
            Color("Background").ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    HStack {
                        Text("Impostazioni")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Spacer()
                        Button { dismiss() } label: {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.1)).frame(width: 36, height: 36)
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)

                    SettingsSection(title: "Connessione") {
                        if let config = oauth.currentConfig {
                            SettingsRow(
                                icon: "server.rack",
                                iconColor: [Color("AccentStart"), Color("AccentEnd")],
                                title: config.host,
                                subtitle: "Porta \(config.port) · \(config.useTLS ? "TLS attivo" : "No TLS")",
                                showChevron: false,
                                action: {}
                            )
                            SettingsRow(
                                icon: wsStatusIcon,
                                iconColor: wsStatusColors,
                                title: wsStatusTitle,
                                subtitle: wsStatusSubtitle
                            ) {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                wsService.disconnect()
                                wsService.connect()
                            }
                        } else {
                            SettingsRow(
                                icon: "network",
                                iconColor: [.orange, .yellow],
                                title: "Configura Home Assistant",
                                subtitle: "Nessuna connessione configurata"
                            ) {
                                dismiss()
                            }
                        }
                    }

                    SettingsSection(title: "Informazioni") {
                        SettingsRow(
                            icon: "info.circle.fill",
                            iconColor: [.gray, .gray.opacity(0.5)],
                            title: "Versione",
                            subtitle: "Wavely AR \(appVersion)",
                            showChevron: false,
                            action: {}
                        )
                        SettingsRow(
                            icon: "house.fill",
                            iconColor: [.teal, .green],
                            title: "Home Assistant",
                            subtitle: "Integrazione via REST + WebSocket",
                            showChevron: false,
                            action: {}
                        )
                        SettingsRow(
                            icon: "arkit",
                            iconColor: [Color("AccentStart"), Color("AccentEnd")],
                            title: "ARKit + RealityKit",
                            subtitle: "Realtà aumentata nativa Apple",
                            showChevron: false,
                            action: {}
                        )
                    }

                    SettingsSection(title: "Account") {
                        SettingsRow(
                            icon: "rectangle.portrait.and.arrow.right",
                            iconColor: [.red, .orange],
                            title: "Disconnetti",
                            subtitle: "Rimuove token e configurazione"
                        ) {
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            wsService.disconnect()
                            oauth.logout()
                            dismiss()
                        }
                    }
                }
                .padding(.bottom, 48)
            }
        }
    }

    private var wsStatusIcon: String {
        switch wsService.connectionState {
        case .connected:    return "checkmark.circle.fill"
        case .connecting:   return "circle.dotted"
        case .reconnecting: return "arrow.clockwise.circle.fill"
        case .disconnected: return "xmark.circle.fill"
        }
    }

    private var wsStatusColors: [Color] {
        switch wsService.connectionState {
        case .connected:    return [.green, .mint]
        case .connecting:   return [.yellow, .orange]
        case .reconnecting: return [.orange, .yellow]
        case .disconnected: return [.red, .orange]
        }
    }

    private var wsStatusTitle: String {
        switch wsService.connectionState {
        case .connected:    return "WebSocket connesso"
        case .connecting:   return "Connessione in corso..."
        case .reconnecting: return "Riconnessione..."
        case .disconnected: return "WebSocket disconnesso"
        }
    }

    private var wsStatusSubtitle: String {
        switch wsService.connectionState {
        case .connected:    return "Aggiornamenti in tempo reale attivi"
        case .connecting:   return "Stabilendo la connessione"
        case .reconnecting: return "Tocca per riconnettere"
        case .disconnected: return "Tocca per riconnettere"
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
                .textCase(.uppercase)
                .kerning(1)
                .padding(.horizontal, 28)
            VStack(spacing: 2) { content }
                .padding(.horizontal, 20)
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let iconColor: [Color]
    let title: String
    let subtitle: String
    var showChevron: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: iconColor,
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                Spacer()
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.25))
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
