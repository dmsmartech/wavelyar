import SwiftUI

struct DiscoveryView: View {
    @ObservedObject private var discovery = HADiscoveryService.shared
    @ObservedObject private var oauth     = HAOAuthService.shared
    @ObservedObject private var appState  = AppState.shared

    @State private var selectedInstance: HADiscoveredInstance?
    @State private var manualHost    = ""
    @State private var manualPort    = "8123"
    @State private var showManual    = false
    @State private var showOAuth     = false
    @State private var connecting    = false
    @State private var errorMessage  = ""

    var body: some View {
        ZStack {
            Color("Background").ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(LinearGradient(
                                colors: [Color("AccentStart"), Color("AccentEnd")],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .padding(.top, 60)

                        Text("Connetti a\nHome Assistant")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)

                        Text("Wavely AR cerca automaticamente le istanze HA disponibili sulla tua rete locale.")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Trovate in rete")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.4))
                                .textCase(.uppercase)
                                .kerning(1)
                            Spacer()
                            if discovery.isScanning {
                                HStack(spacing: 6) {
                                    ProgressView().tint(.white.opacity(0.5)).scaleEffect(0.7)
                                    Text("Scansione...")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                            } else {
                                Button("Ricarica") { discovery.startDiscovery() }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Color("AccentStart"))
                            }
                        }
                        .padding(.horizontal, 24)

                        if discovery.discoveredInstances.isEmpty && !discovery.isScanning {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "wifi.slash")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white.opacity(0.2))
                                    Text("Nessuna istanza trovata")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 24)
                        }

                        ForEach(discovery.discoveredInstances) { instance in
                            HAInstanceRow(instance: instance,
                                          isSelected: selectedInstance?.id == instance.id) {
                                selectedInstance = instance
                                oauth.configure(with: instance.toConfig())
                                showOAuth = true
                            }
                            .padding(.horizontal, 20)
                        }
                    }

                    VStack(spacing: 12) {
                        Button {
                            withAnimation(.spring()) { showManual.toggle() }
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Aggiungi manualmente")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(showManual ? 90 : 0))
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color("AccentStart"))
                            .padding(.horizontal, 24)
                        }

                        if showManual {
                            VStack(spacing: 12) {
                                WavelyTextField(placeholder: "Host o IP (es. 192.168.1.100)",
                                                text: $manualHost)
                                WavelyTextField(placeholder: "Porta (8123)",
                                                text: $manualPort,
                                                keyboardType: .numberPad)
                            }
                            .padding(.horizontal, 20)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.red.opacity(0.8))
                            .padding(.horizontal, 24)
                    }

                    if showManual {
                        WavelyButton(title: connecting ? "Connessione..." : "Connetti",
                                     icon: connecting ? nil : "link",
                                     action: connectManually)
                            .padding(.horizontal, 20)
                            .disabled(connecting || manualHost.isEmpty)
                            .opacity((connecting || manualHost.isEmpty) ? 0.5 : 1)
                    }

                    Spacer(minLength: 40)
                }
            }
        }
        .sheet(isPresented: $showOAuth) {
            if let instance = selectedInstance {
                OAuthView(instance: instance)
            }
        }
        .onAppear  { discovery.startDiscovery() }
        .onDisappear { discovery.stopDiscovery() }
        .onChange(of: oauth.isAuthenticated) { authenticated in
            if authenticated { appState.goToMain() }
        }
    }

    private func connectManually() {
        guard !manualHost.isEmpty else { return }
        errorMessage = ""
        connecting = true
        let port = Int(manualPort) ?? 8123
        let instance = HADiscoveredInstance(name: manualHost, host: manualHost, port: port, useTLS: false)
        selectedInstance = instance
        oauth.configure(with: instance.toConfig())
        showOAuth = true
        connecting = false
    }
}

struct HAInstanceRow: View {
    let instance: HADiscoveredInstance
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color("AccentStart").opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "house.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Color("AccentStart"))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text(instance.displayAddress)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                        .monospacedDigit()
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color("AccentStart"))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.25))
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color("AccentStart").opacity(0.12) : Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isSelected ? Color("AccentStart").opacity(0.4) : .clear, lineWidth: 1))
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
