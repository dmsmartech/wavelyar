import SwiftUI
import ARKit
import RealityKit
import AVFoundation

// MARK: - Shared ARView (singleton — prevents clustering bug on re-entry)

enum SharedARView {
    static let arView: ARView = {
        let v = ARView(frame: .zero)
        v.renderOptions = [.disableMotionBlur]
        return v
    }()
}

// MARK: - WavelyARView

struct WavelyARView: View {
    /// Coda di device da piazzare in sequenza. Può essere 1 (long-press singolo)
    /// o N (multi-selezione dalla lista).
    let devicesToDrop: [HADevice]

    @ObservedObject private var wsService   = HAWebSocketService.shared
    @ObservedObject private var persistence = ARPersistenceService.shared
    @ObservedObject private var restService = HARestService.shared

    private let coordinator = ARCoordinator.shared

    @State private var placementQueue:   [HADevice] = []   // device ancora da piazzare
    @State private var isRelocalizating  = false
    @State private var showRepositionConfirm = false
    @State private var ghostReady        = false
    @State private var editMode          = false
    @State private var deleteMode        = false
    @State private var showDetail        = false
    @State private var selectedDevice:   HADevice?
    @State private var cameraPermission: AVAuthorizationStatus = .notDetermined
    /// Prevents setup() from re-initialising the placement queue on secondary .onAppear
    /// calls (e.g. SwiftUI re-fires .onAppear on the underlying view when a sheet is
    /// dismissed over it). The flag is never reset while the view is visible; it is
    /// automatically destroyed when the view is removed from the hierarchy.
    @State private var didStartPlacement = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch cameraPermission {
            case .authorized:
                arContent
            case .denied, .restricted:
                permissionDeniedView
            default:
                permissionCheckView
            }
        }
        .onAppear { checkPermission() }
    }

    // MARK: - Permission views

    private var permissionCheckView: some View {
        ZStack {
            Color("Background").ignoresSafeArea()
            ProgressView().tint(Color("AccentStart"))
        }
    }

    private var permissionDeniedView: some View {
        ZStack {
            Color("Background").ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 52)).foregroundColor(Color("AccentStart"))
                Text("Permesso Fotocamera")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Wavely AR richiede accesso alla fotocamera per la realtà aumentata.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 40)
                Button("Apri Impostazioni") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                .foregroundColor(Color("AccentStart"))
                Button("Annulla") { dismiss() }
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    // MARK: - AR content

    private var arContent: some View {
        ZStack {
            // ── 1. AR scene (bottom layer)
            ARViewContainer()
                .ignoresSafeArea()
                .onTapGesture { pt in
                    if editMode {
                        // In edit mode tap does nothing (drag handles entities)
                    } else if deleteMode {
                        coordinator.deleteEntity(at: pt)
                    } else if coordinator.deviceToDrop != nil {
                        // Placement mode: tap confirms and advances queue automatically
                        confirmAndAdvance()
                    } else {
                        coordinator.handleTap(at: pt)
                    }
                }

            // ── 2. Gradients
            LinearGradient(colors: [Color("Background").opacity(0.7), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 160).frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea().allowsHitTesting(false)

            LinearGradient(colors: [.clear, Color("Background").opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 200).frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)

            // ── 3. Hand overlays — ALWAYS on top of AR scene
            HandSkeletonOverlay()
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(10)

            LaserRayOverlay()
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(11)

            // ── 4. Surface indicator when placing
            if placementQueue.first != nil {
                PlacementReticle(surfaceFound: ghostReady)
                    .allowsHitTesting(false)
                    .zIndex(9)
            }

            // ── 5. Relocalization banner
            if isRelocalizating { relocalizationBanner.zIndex(8) }

            // ── 6. Edit mode highlight
            if editMode { editModeBanner.zIndex(8) }
            if deleteMode { deleteModeBanner.zIndex(8) }

            // ── 7. UI chrome
            VStack(spacing: 0) {
                topBar
                Spacer()
                if let device = placementQueue.first { placementBanner(device: device) }
                bottomBar
            }
            .zIndex(13)
        }
        .sheet(isPresented: $showDetail) {
            if let d = selectedDevice { DeviceDetailSheet(device: d) }
        }
        .confirmationDialog(
            "Riposiziona elementi",
            isPresented: $showRepositionConfirm,
            titleVisibility: .visible
        ) {
            Button("Trova le posizioni automaticamente", role: .destructive) {
                startRepositioning()
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("La sessione AR verrà riavviata. Punta lentamente la fotocamera verso la stanza: il sistema troverà le posizioni corrette in automatico.")
        }
        .onAppear  { setup() }
        .onDisappear {
            coordinator.cancelPlacement()
            coordinator.persistEditedPositions()    // scale + rotation safety-net (positions NOT touched)
            coordinator.saveWorldMapAndPause()      // salva worldmap → poi pausa (sequenziale)
        }
        // Also save when the app goes to background (covers app-kill scenarios).
        // saveWorldMapAndPause uses UIApplication.beginBackgroundTask to get time
        // to complete the async ARKit world-map callback before the OS suspends us.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                coordinator.persistEditedPositions()
                coordinator.saveWorldMapAndPause()
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Close
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .iconButton()
            }

            Spacer()

            // Environment label
            if let env = persistence.activeEnvironment {
                Text(env.name)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            // Edit mode
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                editMode.toggle()
                deleteMode = false
                coordinator.setEditMode(editMode)
                if !editMode { coordinator.persistEditedPositions() }
            } label: {
                Image(systemName: editMode ? "pencil.circle.fill" : "pencil")
                    .iconButton(active: editMode, activeColor: Color("AccentStart"))
            }

            // Delete mode
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                deleteMode.toggle()
                editMode = false
                coordinator.setEditMode(false)
            } label: {
                Image(systemName: deleteMode ? "trash.fill" : "trash")
                    .iconButton(active: deleteMode, activeColor: .red)
            }

            // Riposiziona — visibile solo se ci sono elementi piazzati
            if !persistence.anchors().isEmpty {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showRepositionConfirm = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .iconButton()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            connectionPill
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                coordinator.saveWorldMap()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 44)
    }

    private var connectionPill: some View {
        Group {
            switch wsService.connectionState {
            case .connected:
                StatusPill(label: "HA Connesso", color: .green, isConnected: true)
            case .connecting, .reconnecting:
                StatusPill(label: "Connessione...", color: .yellow, isConnected: false)
            case .disconnected:
                StatusPill(label: "Disconnesso", color: .red, isConnected: false)
            }
        }
    }

    // MARK: - Banners

    private func placementBanner(device: HADevice) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color("AccentStart"), Color("AccentEnd")],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40)
                Image(systemName: device.domain.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ghostReady ? "Punta la croce sul punto desiderato" : "Cerca una superficie…")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundColor(.white)
                HStack(spacing: 4) {
                    Text(device.friendlyName)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                    if placementQueue.count > 1 {
                        Text("(\(placementQueue.count) rimanenti)")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundColor(Color("AccentStart").opacity(0.8))
                    }
                }
            }
            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var relocalizationBanner: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text("Ricerca ambiente AR…")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundColor(.white)
            Text("Punta lentamente la fotocamera verso\nle superfici della stanza dove hai posizionato gli elementi")
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            // Escape hatch: se le posizioni sono sbagliate l'utente può riposizionare
            // senza aspettare la fine della relocalizzazione
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showRepositionConfirm = true
            } label: {
                Label("Riposiziona elementi", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color("AccentStart").opacity(0.85), in: Capsule())
            }
            .padding(.top, 4)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 120)
        .padding(.horizontal, 24)
    }

    private var editModeBanner: some View {
        Text("✎ Modifica — trascina • pizzica per scala • ruota con 2 dita")
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color("AccentStart").opacity(0.85), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 72)
            .allowsHitTesting(false)
    }

    private var deleteModeBanner: some View {
        Text("🗑 Tocca un dispositivo per rimuoverlo")
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.red.opacity(0.85), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 72)
            .allowsHitTesting(false)
    }

    // MARK: - Setup

    private func checkPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.cameraPermission = granted ? .authorized : .denied
                }
            }
        } else {
            cameraPermission = status
        }
    }

    // MARK: - Repositioning

    /// Riavvia la sessione ARKit con il WorldMap salvato per un riposizionamento
    /// completamente AUTOMATICO. L'utente punta la fotocamera verso la stanza
    /// e ARKit ritrova le posizioni fisiche esatte senza alcuna interazione manuale.
    private func startRepositioning() {
        // Esci da edit / delete mode
        coordinator.cancelPlacement()
        placementQueue = []
        editMode = false
        deleteMode = false
        coordinator.setEditMode(false)

        // Riavvia sessione con WorldMap — ARKit farà la relocalization
        coordinator.restartSessionForRelocalization()
    }

    private func setup() {
        // Always refresh coordinator callbacks — they may capture stale closures.
        coordinator.onRelocalizationStateChanged = { on in
            withAnimation(.easeInOut(duration: 0.3)) { isRelocalizating = on }
        }
        coordinator.onGhostReady = { ready in
            withAnimation { ghostReady = ready }
        }
        coordinator.onEntityTapped = { eid in
            handleEntityTap(entityId: eid)
        }

        // IMPORTANT: guard against secondary .onAppear calls.
        // SwiftUI re-fires .onAppear on the underlying view whenever a sheet that
        // covers it (e.g. DeviceDetailSheet) is dismissed.  Without this guard,
        // placementQueue would be reset to devicesToDrop and beginPlacement() would
        // re-arm coordinator.deviceToDrop — causing confirmPlacement() to call
        // removeAnchor() for already-placed entities and wipe the flat-file.
        guard !didStartPlacement else { return }
        didStartPlacement = true

        // Inizializza la coda e avvia il primo placement
        placementQueue = devicesToDrop
        if let first = placementQueue.first {
            coordinator.beginPlacement(device: first)
        }
    }

    /// Conferma il placement del device corrente e passa immediatamente al successivo.
    private func confirmAndAdvance() {
        coordinator.confirmPlacement()
        if !placementQueue.isEmpty { placementQueue.removeFirst() }
        if let next = placementQueue.first {
            coordinator.beginPlacement(device: next)
        }
    }

    // MARK: - Interactions

    private func handleEntityTap(entityId: String) {
        guard let device = restService.devices.first(where: { $0.entityId == entityId }) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch device.domain {
        case .light:
            wsService.callService(domain: "light",
                                  service: device.isOn ? "turn_off" : "turn_on",
                                  data: ["entity_id": entityId])
            // Refresh bubble after short delay (state update arrives via WS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                coordinator.refreshBubble(entityId: entityId)
            }
        case .switch:
            wsService.callService(domain: "switch",
                                  service: device.isOn ? "turn_off" : "turn_on",
                                  data: ["entity_id": entityId])
        default:
            selectedDevice = device
            showDetail = true
        }
    }

}

// MARK: - ARViewContainer (uses SharedARView singleton to avoid clustering bug)

struct ARViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let arView = SharedARView.arView
        ARCoordinator.shared.startSession(in: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Placement Reticle

struct PlacementReticle: View {
    let surfaceFound: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Outer ring — green when surface detected, amber when searching
            Circle()
                .stroke(surfaceFound ? Color("AccentEnd").opacity(0.6) : Color.orange.opacity(0.5),
                        lineWidth: 1.5)
                .frame(width: 70, height: 70)
                .scaleEffect(pulse ? 1.08 : 1.0)

            // Inner dot
            Circle()
                .fill(surfaceFound ? Color("AccentStart") : Color.orange.opacity(0.7))
                .frame(width: 10, height: 10)

            // Corner marks
            ForEach(0..<4) { i in
                Rectangle()
                    .fill(surfaceFound ? Color.white.opacity(0.7) : Color.orange.opacity(0.5))
                    .frame(width: 12, height: 2)
                    .offset(x: 26)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
        }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

// MARK: - Icon button helper

private extension Image {
    @ViewBuilder
    func iconButton(active: Bool = false, activeColor: Color = Color("AccentStart")) -> some View {
        let base = self
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(active ? activeColor : .white.opacity(0.8))
            .frame(width: 40, height: 40)
        if active {
            base.background(activeColor.opacity(0.2), in: Circle())
        } else {
            base.background(.ultraThinMaterial, in: Circle())
        }
    }
}
