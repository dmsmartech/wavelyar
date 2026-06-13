import SwiftUI
import LocalAuthentication

private let iso8601 = ISO8601DateFormatter()

struct DeviceDetailSheet: View {
    let device: HADevice
    @ObservedObject private var wsService = HAWebSocketService.shared
    @ObservedObject private var persistence = ARPersistenceService.shared
    @ObservedObject private var restService = HARestService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var history: [[HAHistoryState]] = []
    @State private var isLoadingHistory = false
    @State private var lockAuthError: String?
    @State private var currentDevice: HADevice?

    private var displayDevice: HADevice { currentDevice ?? device }

    var body: some View {
        ZStack {
            Color("Background").ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(displayDevice.friendlyName, onDismiss: { dismiss() })

                ScrollView {
                    VStack(spacing: 20) {
                        statusCard
                        controlsCard
                        attributesCard
                        historyCard
                        actionsCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
        }
        .task { await loadHistory() }
        .onReceive(restService.$devices) { devices in
            currentDevice = devices.first(where: { $0.entityId == device.entityId })
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stato attuale")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                    .textCase(.uppercase)
                    .kerning(0.5)
                Text(displayDevice.stateLabel)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            Spacer()
            ZStack {
                Circle()
                    .fill(displayDevice.statusColor.opacity(0.2))
                    .frame(width: 56, height: 56)
                Image(systemName: displayDevice.domain.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(displayDevice.statusColor)
            }
            .shadow(color: displayDevice.statusColor.opacity(0.5), radius: 12)
        }
        .padding(16)
        .background(cardBackground)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsCard: some View {
        switch displayDevice.domain {
        case .light:    lightControls
        case .switch:   switchControls
        case .climate:  climateControls
        case .lock:     lockControls
        default:        EmptyView()
        }
    }

    private var lightControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                WavelyButton(
                    title: "Accendi",
                    icon: "lightbulb.fill",
                    action: { send(domain: "light", service: "turn_on",
                                   data: ["entity_id": displayDevice.entityId]) },
                    style: displayDevice.isOn ? .primary : .secondary
                )
                WavelyButton(
                    title: "Spegni",
                    icon: nil,
                    action: { send(domain: "light", service: "turn_off",
                                   data: ["entity_id": displayDevice.entityId]) },
                    style: displayDevice.isOn ? .secondary : .primary
                )
            }
            if displayDevice.isOn, let brightness = displayDevice.attributes["brightness"]?.doubleValue {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Luminosità: \(Int((brightness / 255.0) * 100))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                        .textCase(.uppercase)
                        .kerning(0.5)
                    BrightnessSlider(brightness: brightness / 255.0) { val in
                        send(domain: "light", service: "turn_on",
                             data: ["entity_id": displayDevice.entityId, "brightness_pct": Int(val * 100)])
                    }
                }
                .padding(16)
                .background(cardBackground)
            }
        }
    }

    private var switchControls: some View {
        HStack(spacing: 12) {
            WavelyButton(
                title: "Attiva",
                icon: "powerplug.fill",
                action: { send(domain: "switch", service: "turn_on",
                               data: ["entity_id": displayDevice.entityId]) },
                style: displayDevice.isOn ? .primary : .secondary
            )
            WavelyButton(
                title: "Disattiva",
                icon: nil,
                action: { send(domain: "switch", service: "turn_off",
                               data: ["entity_id": displayDevice.entityId]) },
                style: displayDevice.isOn ? .secondary : .primary
            )
        }
    }

    private var climateControls: some View {
        HStack(spacing: 20) {
            Button {
                let t = displayDevice.attributes["temperature"]?.doubleValue ?? 20
                send(domain: "climate", service: "set_temperature",
                     data: ["entity_id": displayDevice.entityId, "temperature": t - 0.5])
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(Color("AccentStart"))
            }
            VStack {
                if let target = displayDevice.attributes["temperature"]?.doubleValue {
                    Text("\(String(format: "%.1f", target))°")
                        .font(.system(size: 36, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                }
                if let current = displayDevice.attributes["current_temperature"]?.doubleValue {
                    Text("Attuale: \(String(format: "%.1f", current))°")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            Button {
                let t = displayDevice.attributes["temperature"]?.doubleValue ?? 20
                send(domain: "climate", service: "set_temperature",
                     data: ["entity_id": displayDevice.entityId, "temperature": t + 0.5])
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(Color("AccentStart"))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(cardBackground)
    }

    private var lockControls: some View {
        VStack(spacing: 8) {
            if let error = lockAuthError {
                Text(error).font(.system(size: 13)).foregroundColor(.red.opacity(0.8))
            }
            WavelyButton(
                title: displayDevice.state == "locked" ? "Sblocca" : "Blocca",
                icon: displayDevice.state == "locked" ? "lock.open.fill" : "lock.fill",
                action: authenticateAndToggleLock,
                style: displayDevice.state == "locked" ? .ghost : .primary
            )
        }
    }

    // MARK: - Attributes

    private var attributesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attributi")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
                .textCase(.uppercase)
                .kerning(0.5)

            ForEach(displayDevice.attributes.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                HStack {
                    Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Text(attributeString(value))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    // MARK: - History

    @ViewBuilder
    private var historyCard: some View {
        if isLoadingHistory {
            ProgressView().tint(Color("AccentStart")).frame(maxWidth: .infinity).padding(20)
        } else if let deviceHistory = history.first, !deviceHistory.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Storico 24h")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                    .textCase(.uppercase)
                    .kerning(0.5)

                ForEach(Array(deviceHistory.prefix(8).enumerated()), id: \.offset) { _, state in
                    HStack {
                        Text(state.state ?? "—")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        if let dateStr = state.lastChanged,
                           let date = iso8601.date(from: dateStr) {
                            Text(date, style: .relative)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
            }
            .padding(16)
            .background(cardBackground)
        }
    }

    // MARK: - Actions

    private var actionsCard: some View {
        VStack(spacing: 10) {
            WavelyButton(
                title: "Rimuovi anchor AR",
                icon: "xmark.circle",
                action: {
                    // Percorso di eliminazione COMPLETO: scena + flat-file + salvataggio.
                    // Chiamare solo persistence.removeAnchor lasciava l'entità in scena
                    // e l'elemento risorgeva alla riapertura.
                    ARCoordinator.shared.removeAnchor(entityId: displayDevice.entityId)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                },
                style: .ghost
            )
            if let config = HAOAuthService.shared.currentConfig,
               let url = URL(string: "\(config.baseURL)/lovelace") {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Apri in Home Assistant")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(Color("AccentStart"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color("AccentStart").opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color("AccentStart").opacity(0.3), lineWidth: 1))
                }
            }
        }
    }

    // MARK: - Helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func attributeString(_ value: AnyCodable) -> String {
        if let s = value.stringValue { return s }
        if let d = value.doubleValue { return String(format: "%.1f", d) }
        if let i = value.intValue    { return "\(i)" }
        if let b = value.boolValue   { return b ? "Sì" : "No" }
        return "—"
    }

    private func send(domain: String, service: String, data: [String: Any]) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        wsService.callService(domain: domain, service: service, data: data)
    }

    private func authenticateAndToggleLock() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            lockAuthError = "Biometria non disponibile"
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                localizedReason: "Autorizza controllo serratura") { success, err in
            DispatchQueue.main.async {
                if success {
                    let service = self.displayDevice.state == "locked" ? "unlock" : "lock"
                    self.send(domain: "lock", service: service,
                              data: ["entity_id": self.displayDevice.entityId])
                    self.lockAuthError = nil
                } else {
                    self.lockAuthError = err?.localizedDescription ?? "Autenticazione fallita"
                }
            }
        }
    }

    private func loadHistory() async {
        isLoadingHistory = true
        history = (try? await HARestService.shared.fetchHistory(entityId: device.entityId)) ?? []
        isLoadingHistory = false
    }
}

// MARK: - Brightness Slider

private struct BrightnessSlider: View {
    let brightness: Double
    let onChange: (Double) -> Void
    @State private var value: Double

    init(brightness: Double, onChange: @escaping (Double) -> Void) {
        self.brightness = brightness
        self.onChange = onChange
        _value = State(initialValue: brightness)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.1)).frame(height: 6)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color("AccentStart"), Color("AccentEnd")],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * value, height: 6)
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: Color("AccentStart").opacity(0.5), radius: 6)
                    .offset(x: max(0, geo.size.width * value - 10))
                    .gesture(DragGesture().onChanged { drag in
                        value = max(0.01, min(1.0, drag.location.x / geo.size.width))
                    }.onEnded { _ in onChange(value) })
            }
            .frame(height: 20)
        }
        .frame(height: 20)
    }
}
