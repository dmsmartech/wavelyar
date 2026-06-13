import SwiftUI
import Combine

struct MainListView: View {
    @ObservedObject private var restService = HARestService.shared
    @ObservedObject private var wsService = HAWebSocketService.shared
    @ObservedObject private var persistenceService = ARPersistenceService.shared

    @State private var searchText = ""
    @State private var selectedDomain: HADomain? = nil
    @State private var showSettings = false
    @State private var showARView = false
    @State private var draggedDevice: HADevice?
    @State private var showEnvironmentPicker = false
    @State private var selectionMode = false
    @State private var selectedDevices: Set<String> = []   // entityIds selezionati per AR
    @State private var devicesToDrop: [HADevice] = []      // coda per il multi-placement

    @Environment(\.scenePhase) private var scenePhase

    var filteredDevices: [HADevice] {
        restService.devices.filter { device in
            let matchesDomain = selectedDomain == nil || device.domain == selectedDomain
            let matchesSearch = searchText.isEmpty || device.friendlyName.localizedCaseInsensitiveContains(searchText)
            return matchesDomain && matchesSearch
        }
    }

    var groupedDevices: [(HADomain, [HADevice])] {
        let domains = HADomain.allCases.filter { $0 != .unknown }
        return domains.compactMap { domain in
            let devices = filteredDevices.filter { $0.domain == domain }
            return devices.isEmpty ? nil : (domain, devices)
        }
    }

    var body: some View {
        ZStack {
            Color("Background").ignoresSafeArea()

            VStack(spacing: 0) {
                headerView
                searchAndFilterBar
                deviceList
                if selectionMode && !selectedDevices.isEmpty {
                    placeSelectionBar
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showARView) {
            WavelyARView(devicesToDrop: devicesToDrop)
                .onDisappear {
                    draggedDevice  = nil
                    devicesToDrop  = []
                    selectedDevices = []
                    selectionMode  = false
                }
        }
        .sheet(isPresented: $showEnvironmentPicker) { EnvironmentPickerView() }
        .task {
            await restService.fetchAllDevices()
            wsService.connect()
        }
        // Re-fetch + reconnect when app returns to foreground.
        // The WS reconnect here is a fallback; HAWebSocketService also listens
        // for willEnterForegroundNotification internally.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await restService.fetchAllDevices() }
                if wsService.connectionState != .connected {
                    wsService.connect()
                }
            }
        }
        // Re-fetch when AR sheet is dismissed (user may have added devices via HA app)
        .onChange(of: showARView) { _, isShowing in
            if !isShowing {
                Task { await restService.fetchAllDevices() }
            }
        }
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Wavely AR")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                connectionPill
            }
            Spacer()
            HStack(spacing: 12) {
                Button(action: { showEnvironmentPicker = true }) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                // Tasto selezione multipla
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectionMode.toggle()
                    if !selectionMode { selectedDevices = [] }
                }) {
                    Image(systemName: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(selectionMode ? Color("AccentStart") : .white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(selectionMode ? Color("AccentStart").opacity(0.2) : Color.white.opacity(0.08)))
                }
                // Apri AR (senza selezione = apri direttamente)
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    devicesToDrop = []
                    showARView = true
                }) {
                    Image(systemName: "arkit")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(LinearGradient(colors: [Color("AccentStart"), Color("AccentEnd")],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                        .shadow(color: Color("AccentStart").opacity(0.5), radius: 12)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var connectionPill: some View {
        Group {
            switch wsService.connectionState {
            case .connected:
                StatusPill(label: "Connesso", color: .green, isConnected: true)
            case .connecting:
                StatusPill(label: "Connessione...", color: .yellow, isConnected: false)
            case .reconnecting:
                StatusPill(label: "Riconnessione...", color: .orange, isConnected: false)
            case .disconnected:
                StatusPill(label: "Disconnesso", color: .red, isConnected: false)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: wsService.connectionState == .connected)
    }

    private var placeSelectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedDevices.count) selezionati")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                selectedDevices = []
                selectionMode = false
            }) {
                Text("Annulla")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            }
            Button(action: {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                devicesToDrop = restService.devices.filter { selectedDevices.contains($0.entityId) }
                showARView = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arkit")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Piazza in AR")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(colors: [Color("AccentStart"), Color("AccentEnd")],
                                   startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var searchAndFilterBar: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.35))
                TextField("Cerca dispositivo...", text: $searchText)
                    .foregroundColor(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    DomainFilterChip(title: "Tutti", isSelected: selectedDomain == nil) {
                        selectedDomain = nil
                    }
                    ForEach(HADomain.allCases.filter { $0 != .unknown }, id: \.self) { domain in
                        DomainFilterChip(title: domain.displayName, isSelected: selectedDomain == domain) {
                            selectedDomain = selectedDomain == domain ? nil : domain
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var deviceList: some View {
        Group {
            if restService.isLoading {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .tint(Color("AccentStart"))
                        .scaleEffect(1.5)
                    Text("Caricamento dispositivi...")
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                }
            } else if groupedDevices.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "house.slash.fill")
                        .font(.system(size: 52))
                        .foregroundColor(.white.opacity(0.15))
                    Text("Nessun dispositivo")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Controlla la connessione a Home Assistant")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(.white.opacity(0.25))
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 20, pinnedViews: .sectionHeaders) {
                        ForEach(groupedDevices, id: \.0) { domain, devices in
                            Section {
                                VStack(spacing: 8) {
                                    ForEach(devices) { device in
                                        DeviceRow(
                                            device: device,
                                            selectionMode: selectionMode,
                                            isSelected: selectedDevices.contains(device.entityId)
                                        ) { dragged in
                                            if selectionMode {
                                                // Selezione multipla: toggle
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                if selectedDevices.contains(dragged.entityId) {
                                                    selectedDevices.remove(dragged.entityId)
                                                } else {
                                                    selectedDevices.insert(dragged.entityId)
                                                }
                                            } else {
                                                // Pressione singola: apri AR direttamente
                                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                                devicesToDrop = [dragged]
                                                showARView = true
                                            }
                                        }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(domain.displayName.uppercased())
                                        .font(.system(.caption, design: .rounded, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.35))
                                        .kerning(0.5)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 4)
                                .background(Color("Background"))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
                .refreshable {
                    await restService.fetchAllDevices()
                }
            }
        }
    }
}

private struct DomainFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundColor(isSelected ? .white : .white.opacity(0.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected
                        ? AnyView(LinearGradient(colors: [Color("AccentStart"), Color("AccentEnd")],
                                                 startPoint: .leading, endPoint: .trailing))
                        : AnyView(Color.white.opacity(0.07))
                )
                .clipShape(Capsule())
                .shadow(color: isSelected ? Color("AccentStart").opacity(0.4) : .clear, radius: 8)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

struct DeviceRow: View {
    let device: HADevice
    var selectionMode: Bool = false
    var isSelected: Bool = false
    let onLongPress: (HADevice) -> Void

    @State private var isLifted = false

    private var iconBackground: LinearGradient {
        if device.isUnavailable {
            return LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.06)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [device.statusColor.opacity(0.25), device.statusColor.opacity(0.1)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        HStack(spacing: 14) {
            // Cerchio di selezione (solo in selection mode)
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isSelected ? Color("AccentStart") : .white.opacity(0.35))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 44, height: 44)
                Image(systemName: device.domain.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(device.isUnavailable ? .white.opacity(0.3) : device.statusColor)
            }
            .shadow(color: device.isOn ? device.statusColor.opacity(0.4) : .clear, radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.friendlyName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundColor(device.isUnavailable ? .white.opacity(0.4) : .white)
                Text(device.stateLabel)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()

            if !selectionMode {
                Image(systemName: "arkit")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color("AccentStart").opacity(0.6))
                    .opacity(isLifted ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isLifted)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color("AccentStart").opacity(0.15) : Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color("AccentStart").opacity(0.5) : Color.white.opacity(0.07),
                            lineWidth: isSelected ? 1.5 : 1))
        )
        .scaleEffect(isLifted ? 1.03 : 1.0)
        .shadow(color: isSelected ? Color("AccentStart").opacity(0.2) : isLifted ? Color("AccentStart").opacity(0.3) : .clear, radius: 16)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isLifted)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
        .onLongPressGesture(minimumDuration: selectionMode ? 0.0 : 0.8) {
            isLifted = false
            onLongPress(device)
        } onPressingChanged: { pressing in
            if !selectionMode { isLifted = pressing }
        }
    }
}

extension HADevice {
    var stateLabel: String {
        switch domain {
        case .light:
            if state == "on" {
                if let brightness = attributes["brightness"]?.doubleValue {
                    return "Accesa · \(Int((brightness / 255.0) * 100))%"
                }
                return "Accesa"
            }
            return "Spenta"
        case .switch: return state == "on" ? "Attiva" : "Inattiva"
        case .climate:
            let temp = attributes["current_temperature"]?.doubleValue
            let target = attributes["temperature"]?.doubleValue
            if let t = temp, let tg = target { return "\(Int(t))° → \(Int(tg))°" }
            return state
        case .lock: return state == "locked" ? "Chiusa" : "Aperta"
        case .camera: return "Camera"
        case .binary_sensor:
            let dc = attributes["device_class"]?.stringValue ?? ""
            if dc == "door" || dc == "window" { return state == "on" ? "Aperta" : "Chiusa" }
            return state == "on" ? "Rilevato" : "Nessuno"
        case .sensor:
            let value = attributes["unit_of_measurement"]?.stringValue.map { "\(state) \($0)" } ?? state
            return value
        case .unknown: return state
        }
    }
}

struct EnvironmentPickerView: View {
    @ObservedObject private var persistence = ARPersistenceService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var showNewField = false

    var body: some View {
        ZStack {
            Color("Background").ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader("Ambienti AR", onDismiss: { dismiss() })

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(persistence.environments) { env in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(env.name)
                                        .font(.system(.body, design: .rounded, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("\(env.deviceAnchors.count) dispositivi ancorati")
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                                Spacer()
                                if persistence.activeEnvironment?.id == env.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color("AccentStart"))
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(persistence.activeEnvironment?.id == env.id ? 0.08 : 0.05))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.07), lineWidth: 1))
                            )
                            .onTapGesture {
                                persistence.activeEnvironment = env
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        }

                        if showNewField {
                            HStack {
                                WavelyTextField(placeholder: "Nome ambiente", text: $newName)
                                Button(action: {
                                    if !newName.isEmpty {
                                        persistence.createEnvironment(name: newName)
                                        newName = ""
                                        showNewField = false
                                    }
                                }) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color("AccentStart"))
                                        .frame(width: 44, height: 44)
                                        .background(Color.white.opacity(0.07))
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }

                        WavelyButton(title: "Nuovo ambiente", icon: "plus",
                                     action: { showNewField = true },
                                     style: .ghost)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
        }
    }
}
