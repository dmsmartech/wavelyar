import ARKit
import RealityKit
import SwiftUI
import Combine
import os.log

// Centralised debug logger — filter in Console.app with subsystem "WavelyAR"
private let log = Logger(subsystem: "WavelyAR", category: "AR")

@MainActor
final class ARCoordinator: NSObject, ARSessionDelegate {

    static let shared = ARCoordinator()
    private override init() {
        super.init()
        subscribeToGestures()
    }

    // MARK: - Callbacks
    weak var arView: ARView?
    var onEntityTapped:               ((String) -> Void)?
    var onRelocalizationStateChanged: ((Bool) -> Void)?
    var onGhostReady:                 ((Bool) -> Void)?

    // MARK: - State
    private(set) var deviceToDrop: HADevice?
    var isEditMode = false

    private var ghostAnchor: AnchorEntity?
    private var ghostEntity: ModelEntity?
    private(set) var entityMap: [String: ModelEntity] = [:]

    private var sessionStarted  = false
    private var lastConfig: ARWorldTrackingConfiguration?

    // Edit mode gestures
    private var editPanGesture:      UIPanGestureRecognizer?
    private var editPinchGesture:    UIPinchGestureRecognizer?
    private var editRotationGesture: UIRotationGestureRecognizer?

    // Drag state
    private var draggedEntityId:   String?
    private var dragEntityDepth:   Float?            // camera→entity distance at drag start (fallback)
    private var dragStartEntityPos: SIMD3<Float>?    // element world pos at drag start
    private var dragStartHitPos:    SIMD3<Float>?    // surface hit world pos at drag start

    // Scale state
    private var scalingEntityId:    String?
    private var initialScaleForEdit: SIMD3<Float>?

    // Rotation state
    private var rotatingEntityId: String?

    // Ghost positioning state
    private var ghostHasBeenPositioned = false
    // Last raycast hit that found a real surface (used as freeze-fallback on brief misses).
    private var ghostLastHitTransform: simd_float4x4? = nil
    // Consecutive frames without a valid raycast hit (used to decide when to switch to
    // camera-forward fallback instead of staying frozen at ghostLastHitTransform).
    private var ghostNoHitFrames = 0
    // Tracks the last value sent via onGhostReady so we only fire on state transitions,
    // not 60 times per second from onSceneUpdate.
    private var ghostReadyCurrent = false

    // RealityKit render-loop subscription — for render-synchronous billboard / ghost updates.
    // Stored here so it lives as long as the coordinator singleton and never drops accidentally.
    private var sceneUpdateCancellable: (any Cancellable)?

    // Tracks which environment was active when the AR session was last set up.
    // Used to detect environment switches on session resume.
    private var lastSessionEnvironmentId: String?

    /// User-defined rotation per entity (Z-axis / in-plane).
    /// Billboard applies this on top of the camera-facing orientation every frame.
    private var userRotations: [String: simd_quatf] = [:]

    // Tracks which entities were visible in the previous frame.
    private var lastVisibleEntityIds: Set<String> = []


    // Frame throttling — reduces CPU by spreading expensive ops across frames
    private var frameCounter: UInt64 = 0

    // Background-thread frame counter for Vision throttling.
    // nonisolated(unsafe): incremented only on ARKit's serial background queue,
    // so no actual data race despite being accessed outside the MainActor.
    private nonisolated(unsafe) var bgFrameCounter: UInt64 = 0

    // Pauses hand-gesture Vision ML while plane detection is active (placement / edit mode).
    // Both share the Apple Neural Engine; running them concurrently causes ANE saturation →
    // "ARSession retaining N ARFrames" → "linearization / solving fallback" →
    // world-coordinate drift → elements fly to extreme positions.
    // nonisolated(unsafe): written on MainActor, read on ARKit's background queue.
    // Bool writes/reads are atomic on arm64 — no torn reads possible.
    private nonisolated(unsafe) var handGestureActive = true

    // Cached viewport size for hand-gesture processing.
    // Written on MainActor (per-frame update), read on ARKit's background queue.
    // nonisolated(unsafe): CGSize writes are atomic on arm64; worst case is one
    // stale read per session start — acceptable for Vision viewport sizing.
    nonisolated(unsafe) var cachedViewportSize: CGSize = CGSize(width: 390, height: 844)

    // Relocalization state — true while ARKit is re-finding the saved world map.
    // Elements are hidden during this phase to prevent visible "wrong position" frames.
    private var isRelocalizing = false
    private var relocalizationShowTimer: Timer?

    // Counts how many times we have auto-restarted due to a false-positive relocalization
    // (tooFar check). Capped at 2 to break the restart loop on kill+reopen.
    // NOTE: the allSame check has been REMOVED — it was too tight (< 0.3 m) and fired
    // on every kill+reopen because ARKit clusters anchors temporarily while converging,
    // causing an endless restart loop that cleared all entities every cycle.
    private var relocalizationRestartCount = 0

    // Last gesture command actually sent to each entity.
    // Auto-fire and handleGesture only send a command when the gesture STATE
    // changes for that specific device — prevents re-firing the same command
    // just because the device left and re-entered the camera frame.
    private var lastFiredGesture: [String: HandGesture] = [:]

    // Gesture subscription — lives in singleton so it's never dropped
    private var gestureCancellable: AnyCancellable?

    // MARK: - Gesture subscription

    private func subscribeToGestures() {
        gestureCancellable = HandGestureService.shared.gesturePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] g in self?.handleGesture(g) }
    }

    // MARK: - Gesture handling

    /// Called on every stable gesture state-change (open ↔ fist).
    /// Fires for ALL currently visible devices — no proximity requirement,
    /// just "is the device's bubble on screen right now".
    private func handleGesture(_ gesture: HandGesture) {
        guard let arView else { return }

        // REQUIRED: hand must be physically visible in the camera frame right now.
        // If the user has panned the camera away from their hand, handLandmarks is empty
        // and no devices should be controlled — even if a stable gesture is remembered.
        guard !HandGestureService.shared.handLandmarks.isEmpty else {
            log.info("🤚 Gesture \(gesture == .openHand ? "OPEN" : "FIST") — hand NOT in frame → ignored")
            return
        }

        let visible = visibleEntityIds(in: arView)
        log.info("🤚 Gesture \(gesture == .openHand ? "OPEN" : "FIST") — hand IN frame — visible devices: [\(visible.joined(separator: ", "))]")
        guard !visible.isEmpty else {
            log.info("🤚 No visible entities → gesture ignored")
            return
        }
        fireGesture(gesture, for: visible)
    }

    /// Called every frame. Detects when NEW devices enter the camera view.
    /// If the hand already has a stable pose, fires that pose immediately for
    /// the newly visible devices — no need to change gesture first.
    private func updateVisibilityAndFireForNewDevices(in arView: ARView) {
        let currentVisible = Set(visibleEntityIds(in: arView))
        let newlyVisible   = currentVisible.subtracting(lastVisibleEntityIds)
        let disappeared    = lastVisibleEntityIds.subtracting(currentVisible)

        if !newlyVisible.isEmpty {
            log.info("👁 NEW in frame: [\(newlyVisible.sorted().joined(separator: ", "))]")
        }
        if !disappeared.isEmpty {
            log.info("👁 LEFT frame:   [\(disappeared.sorted().joined(separator: ", "))]")
        }

        // Auto-fire for newly visible devices — but ONLY when the hand is currently
        // visible in the frame. If the hand is not in frame, panning to a new device
        // must never trigger a command by itself.
        // Also skip devices that already received this gesture state (lastFiredGesture)
        // so that re-entering a device's frame doesn't re-fire the same command.
        if !newlyVisible.isEmpty,
           !HandGestureService.shared.handLandmarks.isEmpty,
           let currentGesture = HandGestureService.shared.currentStableGesture {
            let toFire = newlyVisible.filter { lastFiredGesture[$0] != currentGesture }
            if !toFire.isEmpty {
                log.info("👁 Auto-fire \(currentGesture == .openHand ? "OPEN" : "FIST") for new-in-frame (hand visible): [\(toFire.sorted().joined(separator: ", "))]")
                fireGesture(currentGesture, for: Array(toFire))
            } else {
                log.info("👁 Newly visible [\(newlyVisible.sorted().joined(separator: ", "))] already in correct state → skipped")
            }
        }

        lastVisibleEntityIds = currentVisible
    }

    /// Sends HA commands for `gesture` to all `entityIds` that are lights or switches.
    /// Records the sent gesture in `lastFiredGesture` to prevent duplicate commands
    /// when the same device re-enters the camera frame.
    private func fireGesture(_ gesture: HandGesture, for entityIds: [String]) {
        for eid in entityIds {
            guard let device = HARestService.shared.devices.first(where: { $0.entityId == eid }),
                  device.domain == .light || device.domain == .switch else {
                log.debug("🔕 \(eid) skipped (not light/switch or not found)")
                continue
            }
            let domain  = device.domain == .light ? "light" : "switch"
            let service = gesture == .openHand ? "turn_on" : "turn_off"
            guard gesture == .openHand || gesture == .closedFist else { continue }
            log.info("💡 FIRE \(service) → \(eid) (\(domain))")
            HAWebSocketService.shared.callService(domain: domain, service: service,
                                                  data: ["entity_id": eid])
            lastFiredGesture[eid] = gesture   // record so we don't re-fire on re-entry
            scheduleRefresh(eid)
        }
    }

    /// Returns entity IDs whose bubble is currently visible in the camera frame.
    ///
    /// Two-step check:
    ///   1. Entity must be in FRONT of the camera (dot product > 0).
    ///      `arView.project` does NOT return nil for behind-camera entities — it projects
    ///      them mathematically and the result can land inside screen bounds, causing false
    ///      positives (gestures firing for entities behind you).
    ///   2. Projected screen point must be within the view bounds (+ 80 pt margin so
    ///      bubbles at the very edge of screen still count).
    private func visibleEntityIds(in arView: ARView) -> [String] {
        guard let frame = arView.session.currentFrame else { return [] }
        let cam    = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let camFwd = SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)

        var result: [String] = []
        for (eid, model) in entityMap {
            let worldPos  = model.position(relativeTo: nil)
            let toEntity  = worldPos - camPos
            let dotFwd    = simd_dot(toEntity, camFwd)
            let distM     = simd_length(toEntity)

            // 1. Behind camera?
            guard dotFwd > 0 else {
                log.debug("👁 \(eid) BEHIND camera (dot=\(String(format:"%.2f", dotFwd)))")
                continue
            }

            // 2. Project to screen
            guard let screenPt = arView.project(worldPos) else {
                log.debug("👁 \(eid) project→nil (dist=\(String(format:"%.1f", distM))m)")
                continue
            }

            let inBounds = arView.bounds.insetBy(dx: -80, dy: -80).contains(screenPt)
            if inBounds {
                log.debug("👁 \(eid) VISIBLE screen=(\(Int(screenPt.x)),\(Int(screenPt.y))) dist=\(String(format:"%.1f",distM))m")
                result.append(eid)
            } else {
                log.debug("👁 \(eid) off-screen screen=(\(Int(screenPt.x)),\(Int(screenPt.y)))")
            }
        }
        return result
    }


    private func scheduleRefresh(_ entityId: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshBubble(entityId: entityId)
        }
    }

    // MARK: - Session setup

    func startSession(in arView: ARView) {
        self.arView = arView
        cachedViewportSize = arView.bounds.size
        arView.session.delegate = self
        // Disable depth-of-field so the AR scene is never blurred
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField]

        // Subscribe to the RealityKit render loop (SceneEvents.Update fires at display rate,
        // synchronized with each frame render — MainActor). This replaces the old approach of
        // dispatching a Task { @MainActor } from ARKit's background thread every 2nd ARFrame:
        //   OLD: Task dispatch at 30 fps → MainActor queue latency → ghost up to 33 ms stale
        //        at render time → ghost visibly lags/jumps behind the crosshair
        //   NEW: Update fires synchronously before each rendered frame → ghost always at the
        //        CURRENT crosshair position with zero perceptible lag
        // Only subscribed once (shared singleton + shared ARView).
        if sceneUpdateCancellable == nil {
            sceneUpdateCancellable = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                self?.onSceneUpdate()
            }
        }

        let currentEnvId = ARPersistenceService.shared.activeEnvironment?.id

        if sessionStarted, let config = lastConfig {
            if currentEnvId == lastSessionEnvironmentId {
                // Same environment — resume paused session, anchors stay in place
                arView.session.run(config)
                return
            }
            // Environment changed — clear stale entities before loading the new one
            log.info("🌍 Ambiente cambiato (\(self.lastSessionEnvironmentId ?? "nil") → \(currentEnvId ?? "nil")) — pulizia entità e riavvio sessione")
            clearAllEntitiesFromScene()
            // Fall through to set up a fresh session with the new environment
        }
        sessionStarted = true
        lastSessionEnvironmentId = currentEnvId

        let config = ARWorldTrackingConfiguration()
        // Disable environment texturing — it continuously adds AREnvironmentProbeAnchor
        // objects to the session. These accumulate in the WorldMap (635+ per our logs),
        // degrading relocalization quality. UnlitMaterial (our bubble material) ignores
        // environment lighting anyway, so there is no visual downside.
        config.environmentTexturing = .none

        // ── Person segmentation: DISABLED ──────────────────────────────────────
        // personSegmentation runs a CoreML segmentation network on EVERY camera frame
        // (60fps). Combined with HandGestureService Vision ML (10fps), both share the
        // Apple Neural Engine → resource contention → ARKit "resource constraints [33]"
        // → world-coordinate drift → elements fly to extreme positions (796097,-7387026).
        // The visual benefit (hands in front of AR panels) does not justify the ARKit
        // tracking instability it causes. Disabled entirely for stable AR.
        // config.frameSemantics = .personSegmentation  // re-enable only if ANE load solved

        // Start WITHOUT plane detection — dramatically reduces CPU/GPU load
        // and prevents ARKit "resource constraints" that cause tracking instability.
        // Plane detection is enabled only when actively placing or dragging elements.
        config.planeDetection = []
        lastConfig = config

        if let env = ARPersistenceService.shared.activeEnvironment,
           let wm  = ARPersistenceService.shared.loadWorldMap(for: env) {
            config.initialWorldMap = wm
            arView.session.run(config, options: [.resetTracking])
            // Entities are recreated from the flat-file by restoreMissingBubbles()
            // after tracking reaches .normal. If devices aren't loaded yet,
            // HARestService calls restoreMissingBubbles() again after fetch.
        } else {
            arView.session.run(config)
            restoreAnchorsFromPersistence()
        }
    }

    /// Enable/disable plane detection on the fly.
    /// Enabled: during placement ghost and edit-mode drag (need surface raycasts).
    /// Disabled: at all other times — saves CPU/GPU and stabilises world tracking.
    private func setPlaneDetection(_ enabled: Bool) {
        guard let arView, let config = lastConfig as? ARWorldTrackingConfiguration else { return }
        // Horizontal-only: vertical plane detection (walls) saturates ANE alongside world
        // tracking → "resource constraints [33]" → world-frame drift → elements fly.
        // estimatedPlane raycasts work on walls without vertical detection active — ARKit
        // infers wall planes from the environment even without explicit detection.
        let target: ARWorldTrackingConfiguration.PlaneDetection = enabled ? [.horizontal] : []
        guard config.planeDetection != target else { return }
        config.planeDetection = target
        // Run without resetting tracking — just toggles the plane detection feature.
        arView.session.run(config, options: [])
        log.info("🛩 PlaneDetection \(enabled ? "ON" : "OFF")")
    }

    func pauseSession() {
        arView?.session.pause()
    }

    /// Saves the world map and THEN pauses the session.
    /// Uses UIApplication.beginBackgroundTask so iOS gives us time to complete
    /// the async world map write even when the app is being killed/backgrounded.
    func saveWorldMapAndPause() {
        guard let arView, let env = ARPersistenceService.shared.activeEnvironment else {
            arView?.session.pause()
            return
        }

        // Request background execution time so the async callback can complete
        // even if the system is suspending the app.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "WavelyAR.SaveWorldMap") {
            // Expiry handler — system is about to force-kill us; clean up.
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        // Il WorldMap viene salvato SENZA anchor: serve solo da nuvola di feature
        // per la relocalizzazione. Le posizioni vivono nel flat-file (vedi nota
        // architettura sopra didAdd) e non possono essere corrotte da oscillazioni
        // del frame al momento del salvataggio.
        arView.session.getCurrentWorldMap { [weak self] worldMap, error in
            Task { @MainActor [weak self] in
                if let wm = worldMap {
                    wm.anchors = []
                    ARPersistenceService.shared.saveWorldMap(wm, for: env)
                    log.info("💾 WorldMap salvato (solo nuvola di feature, 0 anchor) → pausa sessione")
                } else {
                    log.warning("⚠️ WorldMap save failed: \(error?.localizedDescription ?? "unknown") → pausing anyway")
                }
                self?.arView?.session.pause()
                // Release background task token
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
        }
    }

    // MARK: - Restore saved anchors (no WorldMap case)

    private func restoreAnchorsFromPersistence() {
        guard let arView else { return }
        let saved = ARPersistenceService.shared.anchors()
        log.info("🗂 restoreAnchorsFromPersistence — \(saved.count) anchor nel flat-file")
        for s in saved {
            guard entityMap[s.entityId] == nil else {
                log.debug("🗂   skip \(s.entityId) — già in entityMap")
                continue
            }
            guard let t = simd_float4x4.fromArray(s.transform) else {
                log.error("🗂   ❌ \(s.entityId) — transform non valido: \(s.transform)")
                continue
            }
            let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            log.debug("🗂   \(s.entityId) — flat-file pos=(\(String(format:"%.2f",pos.x)), \(String(format:"%.2f",pos.y)), \(String(format:"%.2f",pos.z)))")
            guard let dev = HARestService.shared.devices.first(where: { $0.entityId == s.entityId }) else {
                log.warning("🗂   ⚠️ \(s.entityId) — device non trovato in HARestService")
                continue
            }
            addBubble(to: arView, transform: t, device: dev)
            log.info("🗂   ✅ \(s.entityId) — bolla creata dal flat-file")
        }
    }

    /// Called by HARestService after devices load AND from the post-stabilization
    /// block. Creates a bubble for every flat-file entry not yet in scene.
    /// FLAT-FILE ONLY — session/WorldMap anchors are never consulted (see the
    /// architecture note above didAdd). Idempotent: the entityMap guard prevents
    /// duplicates, so it can be called from multiple code paths safely.
    func restoreMissingBubbles() {
        guard let arView else { return }
        for s in ARPersistenceService.shared.anchors() {
            guard entityMap[s.entityId] == nil,
                  let dev = HARestService.shared.devices.first(where: { $0.entityId == s.entityId }),
                  let t = simd_float4x4.fromArray(s.transform)
            else { continue }
            addBubble(to: arView, transform: t, device: dev)
            log.info("✅ restoreMissingBubbles: bolla creata dal flat-file '\(s.entityId)'")
        }
    }

    // MARK: - ARSessionDelegate

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        bgFrameCounter &+= 1

        // Vision ML at ~5 fps — see detailed comment in the original version.
        // Billboard, ghost, and visibility updates are now handled by onSceneUpdate()
        // which runs render-synchronously at display rate (see startSession subscription).
        // This eliminates the 30fps async Task that caused ghost lag behind the crosshair.
        if case .normal = frame.camera.trackingState,
           bgFrameCounter % 12 == 0,
           handGestureActive {
            HandGestureService.shared.processFrame(frame.capturedImage,
                                                   viewportSize: cachedViewportSize)
        }
    }

    // Called by the SceneEvents.Update subscription — fires render-synchronously at
    // display rate (60 fps on most devices), on the MainActor.
    // Moving here from the old "Task { @MainActor } every 2nd ARFrame" approach:
    //   • Billboard: was 30fps async → entities visibly wobbled when world frame shifted.
    //     Now 60fps sync → orientation computed from the CURRENT frame's camera transform,
    //     zero latency.
    //   • Ghost: was 30fps async → up to 33ms stale at render time → ghost lagged behind
    //     the crosshair when the camera moved. Now 60fps sync → ghost ALWAYS at the
    //     current crosshair position, visually locked to the reticle.
    @MainActor
    private func onSceneUpdate() {
        guard let arView, let frame = arView.session.currentFrame else { return }
        cachedViewportSize = arView.bounds.size

        // Ghost position must be updated BEFORE billboard so the billboard orientation
        // is computed from the already-correct entity world position.
        updateGhostPosition()
        billboardAllBubbles(cameraTransform: frame.camera.transform)

        // Visibility / gesture-fire at ~10 fps (every 6th render frame at 60fps)
        frameCounter &+= 1
        if frameCounter % 6 == 0 {
            updateVisibilityAndFireForNewDevices(in: arView)
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ARCHITETTURA DELLA PERSISTENZA (riscritta)
    //
    // FLAT-FILE = UNICA fonte di verità per ESISTENZA e POSIZIONE degli elementi.
    //   • piazzamento  → scrive il flat-file
    //   • drag         → aggiorna il flat-file
    //   • eliminazione → rimuove dal flat-file (DEFINITIVA: nulla può risuscitarla)
    //
    // WORLDMAP = SOLO dati di relocalizzazione (nuvola di feature point).
    //   • al salvataggio viene SVUOTATO di tutti gli anchor (wm.anchors = [])
    //   • al caricamento eventuali anchor (mappe vecchie) vengono RIMOSSI e ignorati
    //
    // Perché: ARKit, sotto resource-constraints, oscilla tra ipotesi di frame
    // distanti metri. Qualsiasi pipeline che legga posizioni dagli anchor di
    // sessione (didAdd / didUpdate / getCurrentWorldMap) cattura coordinate di
    // un frame arbitrario → elementi che ballano, salvataggi corrotti, elementi
    // eliminati che risorgono. Con il flat-file come unica verità le coordinate
    // sono deterministiche: ciò che piazzi è ESATTAMENTE ciò che ritrovi.
    // ════════════════════════════════════════════════════════════════════════

    /// Gli anchor nominati nel WorldMap NON creano più bolle e NON rigenerano il
    /// flat-file: vengono rimossi e basta. Le bolle nascono SOLO dal flat-file
    /// (restoreMissingBubbles / confirmPlacement). Questo elimina alla radice:
    ///   • la resurrezione di elementi eliminati (l'anchor sopravviveva nella
    ///     mappa o nella sessione e ricreava bolla + voce flat-file)
    ///   • le posizioni corrotte dal frame sbagliato durante le oscillazioni
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor [weak self] in
            guard let self, let av = self.arView else { return }
            for anchor in anchors {
                guard let eid = anchor.name, !eid.isEmpty else { continue }   // sistema: ignora
                av.session.remove(anchor: anchor)
                log.info("🧹 didAdd: anchor legacy '\(eid)' rimosso dalla sessione (le bolle nascono solo dal flat-file)")
            }
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch camera.trackingState {
            case .limited(.relocalizing):
                guard !self.isRelocalizing else { break }   // already in this state
                self.isRelocalizing = true
                self.onRelocalizationStateChanged?(true)

                // Suspend Vision ML during relocalization: ARKit's reloc solver and the
                // Vision hand-pose network compete for the Apple Neural Engine.
                // Running both causes "resource constraints [33]" → tracking degrades →
                // the world coordinate system shifts → elements appear at wrong positions
                // after the reloc declares success. Gestures are also meaningless while
                // elements are hidden, so nothing is lost by suspending here.
                self.handGestureActive = false

                // ── Hide debounce ────────────────────────────────────────────────
                // ARKit oscillates briefly between .limited and .normal during normal
                // use (insufficient features, camera motion, etc.).  Hiding immediately
                // causes elements to flicker or vanish for a split-second and then
                // reappear — visually jarring. Wait 2 s: if tracking recovers within
                // that window, elements are never hidden.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, self.isRelocalizing else { return }
                    for model in self.entityMap.values { model.isEnabled = false }
                }

                self.relocalizationShowTimer?.invalidate()
                self.relocalizationShowTimer = Timer.scheduledTimer(
                    withTimeInterval: 30.0, repeats: false
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, let arView = self.arView else { return }
                        self.isRelocalizing = false
                        // Ricrea entità dal flat-file anche al timeout — best-effort
                        let savedRot = self.userRotations
                        for eid in Array(self.entityMap.keys) {
                            arView.scene.findEntity(named: "anchor_\(eid)")?.removeFromParent()
                            self.entityMap.removeValue(forKey: eid)
                        }
                        self.userRotations = savedRot
                        self.restoreAnchorsFromPersistence()
                        self.onRelocalizationStateChanged?(false)
                        // Restore Vision ML after timeout (same policy as post-stabilization).
                        if self.deviceToDrop == nil && !self.isEditMode {
                            self.handGestureActive = true
                        }
                        log.warning("📍 Relocalization timeout (30 s) — ambiente non trovato, elementi mostrati in posizione approssimata")
                    }
                }
                log.info("📍 Tracking: relocalizing — elementi nascosti tra 2 s (attesa max 30 s, inquadra la stanza)")

            case .normal:
                self.relocalizationShowTimer?.invalidate()
                self.relocalizationShowTimer = nil
                let wasRelocalizing = self.isRelocalizing
                self.isRelocalizing = false   // clear immediately so new placements work

                guard wasRelocalizing else {
                    // Tracking bounced back to .normal quickly — just re-enable entities
                    for model in self.entityMap.values { model.isEnabled = true }
                    // Restore Vision ML if we suspended it at .relocalizing and we're
                    // not currently in placement or edit mode (which manage it separately).
                    if self.deviceToDrop == nil && !self.isEditMode {
                        self.handGestureActive = true
                    }
                    break
                }

                // ── Stabilization delay ──────────────────────────────────────────
                // ARKit often declares .normal prematurely — the coordinate system hasn't
                // fully converged yet.  Waiting 2.5 s lets the internal optimiser converge
                // before we recreate entities at their saved world positions.
                //
                // ── False-positive detection ─────────────────────────────────────
                // The ONLY remaining sanity check is tooFar (> 20 m): a genuinely bad
                // relocalization (wrong feature cluster) would project anchors meters or
                // tens of meters from the camera.
                //
                // The allSame check (< 0.3 m between anchors) has been REMOVED because
                // it fired on every kill+reopen: ARKit temporarily clusters anchor world
                // positions during the first 1-2 s of convergence, triggering a restart
                // loop (up to 10+ cycles) that cleared entities on every iteration.
                // Entities placed on the same wall can legitimately be < 0.3 m apart,
                // so the threshold was both too tight and semantically wrong.
                //
                // tooFar is capped at 2 restarts (relocalizationRestartCount) to break
                // any residual loop — after 2 attempts we show entities as-is and log.
                let restartAttempt = self.relocalizationRestartCount
                log.info("📍 Tracking: normal — stabilizzazione in corso (2.5 s), tentativo restart #\(restartAttempt)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self, !self.isRelocalizing, let arView = self.arView else { return }

                    // ── Log posizioni correnti ────────────────────────────────────
                    let worldPositions = self.entityMap.values.map { $0.position(relativeTo: nil) }
                    log.info("📍 [post-stabilizzazione] entità in scena: \(worldPositions.count)")
                    for (idx, pos) in worldPositions.enumerated() {
                        log.debug("📍   entity[\(idx)] worldPos=(\(String(format: "%.2f", pos.x)), \(String(format: "%.2f", pos.y)), \(String(format: "%.2f", pos.z)))")
                    }

                    // ── tooFar sanity check ───────────────────────────────────────
                    // Entità > 20 m dalla camera → relocalization falsa.
                    // Cap a 2 restart per evitare loop.
                    if self.relocalizationRestartCount < 2,
                       let frame = arView.session.currentFrame {
                        let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                                  frame.camera.transform.columns.3.y,
                                                  frame.camera.transform.columns.3.z)
                        let farDistances = worldPositions.map { simd_distance($0, camPos) }
                        if farDistances.contains(where: { $0 > 20 }) {
                            log.warning("📍 Relocalization FALSA — entità > 20 m dalla camera, restart #\(self.relocalizationRestartCount + 1)/2")
                            self.relocalizationRestartCount += 1
                            self.restartSessionForRelocalization()
                            return
                        }
                    }

                    // ── Mostra tutte le entità ────────────────────────────────────
                    // Potrebbero essere nascoste dal debounce 2s del .relocalizing.
                    for model in self.entityMap.values { model.isEnabled = true }

                    self.relocalizationRestartCount = 0
                    self.onRelocalizationStateChanged?(false)
                    log.info("📍 Tracking: normal — \(self.entityMap.count) entità abilitate")

                    // ── Recupero elementi solo nel flat-file ──────────────────────
                    // restoreMissingBubbles agisce su:
                    //   1. Elementi nel flat-file ma NON nel WorldMap (anchor mai salvato —
                    //      es. app killata subito dopo il piazzamento prima che
                    //      getCurrentWorldMap completasse la callback async).
                    //   2. Dopo restartSessionForRelocalization: clearAllEntitiesFromScene
                    //      cancella entityMap; didAdd ricrea solo gli anchor nel WorldMap.
                    //      Gli anchor solo-flat-file sarebbero persi senza questa chiamata.
                    // È idempotente: il guard `entityMap[eid] == nil` evita duplicati.
                    // Se HARestService non ha ancora caricato i device, la chiamata è no-op
                    // (devices vuoti → guard fallisce); la versione definitiva viene
                    // invocata da HARestService stesso dopo il fetch.
                    self.restoreMissingBubbles()
                    log.info("📍 Post-stabilization restoreMissingBubbles completato — entityMap: \(self.entityMap.count) entità")

                    // Resume Vision ML now that ARKit is stable and elements are visible.
                    // Skip if in placement or edit mode (those manage handGestureActive themselves).
                    if self.deviceToDrop == nil && !self.isEditMode {
                        self.handGestureActive = true
                        log.info("📍 Vision ML ripreso dopo stabilizzazione post-reloc")
                    }

                    // ── Salvataggio proattivo WorldMap ────────────────────────────
                    // Cattura tutte le entità correnti nel WorldMap per il prossimo restart.
                    self.saveWorldMap()
                }

            case .limited:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {}

    // MARK: - Billboard (face camera every frame)

    private func billboardAllBubbles(cameraTransform: simd_float4x4) {
        // In edit mode billboard is paused so rotation/scale/drag gestures work correctly.
        guard !isEditMode else { return }

        let camPos = SIMD3<Float>(cameraTransform.columns.3.x,
                                   cameraTransform.columns.3.y,
                                   cameraTransform.columns.3.z)

        let worldUp = SIMD3<Float>(0, 1, 0)
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        for (eid, model) in entityMap {
            let worldPos = model.position(relativeTo: nil)
            let toCamera = camPos - worldPos
            let dist     = simd_length(toCamera)
            guard dist > 0.01 else { continue }

            let forward = toCamera / dist

            var right = cross(worldUp, forward)
            let rightLen = simd_length(right)

            if rightLen < 0.1 {
                let camRx = cameraTransform.columns.0.x
                let camRz = cameraTransform.columns.0.z
                let hLen  = sqrt(camRx * camRx + camRz * camRz)
                right = hLen > 0.01
                    ? SIMD3<Float>(camRx / hLen, 0, camRz / hLen)
                    : SIMD3<Float>(1, 0, 0)
            } else {
                right = right / rightLen
            }

            let up = normalize(cross(forward, right))

            let rotMatrix = float3x3(columns: (right, up, forward))
            let billboard = simd_normalize(simd_quatf(rotMatrix))

            let userRot = userRotations[eid] ?? identity
            model.setOrientation(billboard * userRot, relativeTo: nil)
        }

        // Il ghost è figlio di AnchorEntity(.camera): la sua faccia (+Z locale)
        // è già orientata verso l'utente per costruzione — nessun billboard necessario.
    }

    // MARK: - Ghost (placement preview)

    func beginPlacement(device: HADevice) {
        guard let arView else { return }
        cancelPlacement()
        deviceToDrop = device
        setPlaneDetection(true)   // need surfaces for ghost positioning and placement raycast

        // AnchorEntity(.camera) = il ghost è vincolato alla camera.
        // La posizione locale (0, 0, -depth) lo tiene SEMPRE al centro della croce (X=Y=0).
        // Solo il Z viene aggiornato da updateGhostPosition() con la distanza dalla superficie,
        // così l'utente vede l'anteprima alla profondità corretta (parete lontana = più piccolo,
        // tavolo vicino = più grande) senza che il ghost si sposti mai dalla croce.
        let camAnchor = AnchorEntity(.camera)
        ghostAnchor   = camAnchor
        ghostEntity   = makeBubbleEntity(for: device, alpha: 0.6)
        ghostEntity!.position = SIMD3<Float>(0, 0.064, -1.0)   // +0.064 = height/2: compensa origine in cima al piano
        camAnchor.addChild(ghostEntity!)
        arView.scene.addAnchor(camAnchor)
        ghostHasBeenPositioned = true    // sempre visibile: nessun hide iniziale
        ghostLastHitTransform  = nil
        ghostNoHitFrames       = 0
        ghostReadyCurrent      = false
        handGestureActive = false  // plane detection ON → suspend Vision to prevent ANE overload
    }

    func cancelPlacement() {
        ghostAnchor?.removeFromParent()
        ghostAnchor  = nil
        ghostEntity  = nil
        deviceToDrop = nil
        ghostHasBeenPositioned = false
        ghostLastHitTransform  = nil
        ghostNoHitFrames       = 0
        ghostReadyCurrent      = false
        onGhostReady?(false)
        setPlaneDetection(false)   // no longer need surface detection
        handGestureActive = true   // plane detection OFF → resume Vision
    }

    private func updateGhostPosition() {
        guard let arView, deviceToDrop != nil else { return }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)

        if let q = arView.makeRaycastQuery(from: center,
                                           allowing: .estimatedPlane,
                                           alignment: .any),
           let r = arView.session.raycast(q).first {
            let cam    = arView.session.currentFrame?.camera.transform ?? simd_float4x4(1)
            let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            let hitPos = SIMD3<Float>(r.worldTransform.columns.3.x,
                                      r.worldTransform.columns.3.y,
                                      r.worldTransform.columns.3.z)
            let depth = max(0.15, simd_distance(camPos, hitPos))
            // +0.064 = height/2: il piano ha l'origine al bordo superiore, questo lo centra sulla croce
            ghostEntity?.position = SIMD3<Float>(0, 0.064, -depth)
            ghostLastHitTransform = r.worldTransform
            ghostNoHitFrames      = 0
            if !ghostReadyCurrent {
                ghostReadyCurrent = true
                onGhostReady?(true)
            }
        } else {
            ghostNoHitFrames += 1
            if ghostNoHitFrames >= 6, ghostReadyCurrent {
                ghostReadyCurrent = false
                onGhostReady?(false)
            }
        }
    }

    // MARK: - Confirm placement

    func confirmPlacement() {
        guard let arView, let device = deviceToDrop,
              let frame = arView.session.currentFrame else { return }

        var transform: simd_float4x4

        // Priority 1: fresh raycast at the exact tap instant — most accurate.
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let q = arView.makeRaycastQuery(from: center,
                                           allowing: .estimatedPlane,
                                           alignment: .any),
           let r = arView.session.raycast(q).first {
            transform = simd_float4x4(1)
            transform.columns.3 = r.worldTransform.columns.3
            let p = transform.columns.3
            log.info("📍 Placement: fresh raycast at (\(String(format:"%.2f",p.x)),\(String(format:"%.2f",p.y)),\(String(format:"%.2f",p.z)))")

        // Priority 2: last confirmed surface hit from updateGhostPosition().
        } else if let last = ghostLastHitTransform {
            transform = last
            let p = transform.columns.3
            log.info("📍 Placement: using cached ghost hit at (\(String(format:"%.2f",p.x)),\(String(format:"%.2f",p.y)),\(String(format:"%.2f",p.z)))")

        // Priority 3: fallback — 1.5 m davanti alla camera.
        // (ghostAnchor è ora AnchorEntity(.camera): il suo transform è in camera space,
        //  non world space — non usabile come posizione di piazzamento.)
        } else {
            let cam    = frame.camera.transform
            let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            let camFwd = -normalize(SIMD3<Float>(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z))
            let fallbackPos = camPos + camFwd * 1.5
            transform = simd_float4x4(1)
            transform.columns.3 = SIMD4<Float>(fallbackPos.x, fallbackPos.y, fallbackPos.z, 1)
            log.info("📍 Placement fallback: 1.5m in front of camera at (\(String(format:"%.2f",fallbackPos.x)),\(String(format:"%.2f",fallbackPos.y)),\(String(format:"%.2f",fallbackPos.z)))")
        }

        cancelPlacement()

        // If this entity is already placed, remove it first so it can be re-placed
        // at the new position. This allows the user to reposition an existing element
        // by dragging it from the list again and pressing "Ancora".
        if entityMap[device.entityId] != nil {
            log.info("📍 Entity \(device.entityId) already exists — removing before re-placement")
            // savesWorldMap: false — confirmPlacement saves AFTER adding the new anchor,
            // so we never write a WorldMap with this element missing.
            removeAnchor(entityId: device.entityId, savesWorldMap: false)
        }

        // Flat-file only — nessun anchor ARKit (vedi nota architettura sopra didAdd).
        // L'ARAnchor qui è solo un contenitore per la firma di addAnchor; non viene
        // MAI aggiunto alla sessione.
        let record = ARAnchor(name: device.entityId, transform: transform)
        ARPersistenceService.shared.addAnchor(record, entityId: device.entityId)
        addBubble(to: arView, transform: transform, device: device)
        saveWorldMap()   // aggiorna la nuvola di feature per la prossima relocalizzazione
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    // MARK: - Bubble creation

    func addBubble(to arView: ARView, transform: simd_float4x4, device: HADevice) {
        let eid = device.entityId
        guard entityMap[eid] == nil else { return }

        // AnchorEntity(world:) — posizione FISSA in coordinate mondo.
        //
        // Perché NON AnchorEntity(.anchor(identifier:)):
        //   ARKit traccia l'anchor contro i feature point locali. Sul soffitto, pareti
        //   bianche o zone prive di texture non ci sono feature → l'anchor deriva
        //   all'infinito (oscillazione visibile).
        //
        // Perché world: funziona:
        //   Dopo relocalization riuscita + 1.5 s di stabilizzazione, il sistema di
        //   coordinate del mondo corrisponde al WorldMap. Le trasformate salvate
        //   nel flat-file sono già in quelle coordinate → posizione fisica corretta.
        //   Con world: l'entità non si muove MAI da sola — stabile su soffitto, pareti
        //   e qualsiasi superficie.
        //
        // Billboard: model.setOrientation(relativeTo: nil) imposta l'orientamento
        //   MONDO direttamente, ignorando la rotazione del parent AnchorEntity.
        let anchorEnt = AnchorEntity(world: transform)
        anchorEnt.name = "anchor_\(eid)"

        let model = makeBubbleEntity(for: device, alpha: 1.0)
        model.name = eid
        model.generateCollisionShapes(recursive: false)

        // Restore saved scale and user-rotation from flat-file.
        let saved = ARPersistenceService.shared.anchors().first(where: { $0.entityId == eid })
        if let s = saved {
            let scale = s.modelScaleValue
            if scale.x > 0, scale.y > 0, scale.z > 0 { model.scale = scale }
            userRotations[eid] = s.modelRotationValue
        }

        // Hide if relocalization is still in progress — shown after .normal or timeout.
        // New placements (confirmPlacement) always happen at .normal so isRelocalizing
        // is false for them; the element appears immediately as expected.
        model.isEnabled = !isRelocalizing

        entityMap[eid] = model
        anchorEnt.addChild(model)
        addStem(to: anchorEnt)
        arView.scene.addAnchor(anchorEnt)
    }

    // MARK: - Bubble mesh (PLANE not box — no black sides)

    private func makeBubbleEntity(for device: HADevice, alpha: CGFloat) -> ModelEntity {
        // Plane: single face, no sides, no back → no black border
        // 0.24 × 0.128 m matches the 300:160 render ratio exactly
        let mesh   = MeshResource.generatePlane(width: 0.24, height: 0.128, cornerRadius: 0.018)
        let entity = ModelEntity(mesh: mesh,
                                 materials: [UnlitMaterial(color: .white)])
        entity.name = device.entityId

        // Defer texture rendering to avoid blocking MainActor during confirmPlacement.
        // ImageRenderer (SwiftUI → UIImage) takes ~100-200 ms on the main thread.
        // If called synchronously it blocks MainActor, causing ARKit to queue 11+ ARFrames
        // → camera dropout → tracking failure → elements disappear.
        // With this deferral the entity shows as white for ≤1 frame, then gets its texture.
        let dev = device
        let a   = alpha
        Task { @MainActor [weak entity, weak self] in
            guard let entity, let self else { return }
            self.applyBubbleTexture(for: dev, onto: entity, alpha: a)
        }
        return entity
    }

    private func applyBubbleTexture(for device: HADevice, onto entity: ModelEntity, alpha: CGFloat) {
        let w = DeviceBubbleSnapshot.renderWidth
        let h = DeviceBubbleSnapshot.renderHeight
        let renderer = ImageRenderer(content:
            DeviceBubbleSnapshot(device: device).frame(width: w, height: h)
        )
        renderer.scale = 2.0

        guard let img = renderer.uiImage,
              let cg  = img.cgImage,
              let tex = try? TextureResource.generate(from: cg, options: .init(semantic: .color))
        else { return }

        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor.white.withAlphaComponent(alpha), texture: .init(tex))
        entity.model?.materials = [mat]
    }

    private func addStem(to parent: AnchorEntity) {
        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor.white.withAlphaComponent(0.45))

        let line = ModelEntity(
            mesh: MeshResource.generateBox(width: 0.002, height: 0.05, depth: 0.002, cornerRadius: 0.001),
            materials: [mat]
        )
        line.position = SIMD3(0, -0.09, 0)
        parent.addChild(line)

        var dotMat = UnlitMaterial()
        dotMat.color = .init(tint: UIColor.white.withAlphaComponent(0.65))
        let dot = ModelEntity(mesh: MeshResource.generateSphere(radius: 0.005), materials: [dotMat])
        dot.position = SIMD3(0, -0.115, 0)
        parent.addChild(dot)
    }

    // MARK: - Tap / Delete

    func handleTap(at point: CGPoint) {
        guard let arView else { return }
        if deviceToDrop != nil { confirmPlacement(); return }

        for hit in arView.hitTest(point) {
            let name = hit.entity.name
            guard !name.isEmpty,
                  !name.hasPrefix("anchor_"),
                  name != "line", name != "dot" else { continue }
            onEntityTapped?(name)
            return
        }
    }

    func deleteEntity(at point: CGPoint) {
        guard let arView else { return }
        for hit in arView.hitTest(point) {
            let name = hit.entity.name
            guard !name.isEmpty, !name.hasPrefix("anchor_") else { continue }
            removeAnchor(entityId: name)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
    }

    /// Rimozione DEFINITIVA di un elemento. Il flat-file è l'unica fonte di verità
    /// (vedi nota architettura sopra didAdd): tolto da lì, nulla può risuscitarlo.
    /// - Parameter savesWorldMap: `false` quando chiamato da `confirmPlacement`
    ///   (flusso di sostituzione) — il salvataggio lo fa confirmPlacement stesso.
    func removeAnchor(entityId: String, savesWorldMap: Bool = true) {
        guard let arView else { return }
        // 1. Remove from RealityKit scene
        arView.scene.findEntity(named: "anchor_\(entityId)")?.removeFromParent()
        entityMap.removeValue(forKey: entityId)
        userRotations.removeValue(forKey: entityId)
        // 2. Legacy cleanup: rimuovi eventuali anchor ARKit residui di vecchie build.
        //    (La pipeline attuale non crea più anchor di sessione.)
        for oldAnchor in (arView.session.currentFrame?.anchors ?? [])
            where oldAnchor.name == entityId {
            arView.session.remove(anchor: oldAnchor)
        }
        // 3. Remove from flat-file — QUESTA è l'eliminazione vera.
        ARPersistenceService.shared.removeAnchor(entityId: entityId)
        log.info("🗑 Elemento '\(entityId)' eliminato dal flat-file (definitivo)")
        if savesWorldMap { saveWorldMap() }
    }

    // MARK: - Repositioning

    /// Removes all placed entities from the RealityKit scene and ARKit session
    /// WITHOUT touching ARPersistenceService (flat-file anchors are kept).
    /// Call this before starting a manual reposition flow so `confirmPlacement`
    /// will overwrite the old anchor positions with the new ones.
    func clearAllEntitiesFromScene() {
        guard let arView else { return }
        for eid in Array(entityMap.keys) {
            // Remove from RealityKit
            arView.scene.findEntity(named: "anchor_\(eid)")?.removeFromParent()
            // Remove ALL same-name ARKit anchors (duplicates accumulate across re-placements)
            for old in (arView.session.currentFrame?.anchors ?? []) where old.name == eid {
                arView.session.remove(anchor: old)
            }
            entityMap.removeValue(forKey: eid)
            userRotations.removeValue(forKey: eid)
        }
        log.info("🔄 Cleared all entities from scene for repositioning")
    }

    /// Riavvia la sessione ARKit con il WorldMap salvato (sola nuvola di feature)
    /// per riallineare il sistema di coordinate. ARKit entra in .limited(.relocalizing);
    /// quando raggiunge .normal, il blocco post-stabilizzazione chiama
    /// restoreMissingBubbles() che ricrea le entità dalle posizioni del flat-file.
    func restartSessionForRelocalization() {
        guard let arView,
              let env = ARPersistenceService.shared.activeEnvironment,
              let wm  = ARPersistenceService.shared.loadWorldMap(for: env) else {
            log.warning("⚠️ restartSessionForRelocalization: no WorldMap saved — cannot relocalize")
            return
        }

        // 1. Reset timer and relocalization state (the new session will re-trigger it)
        relocalizationShowTimer?.invalidate()
        relocalizationShowTimer = nil
        isRelocalizing = false

        // 2. Clear all entities from scene (they'll be recreated after relocalization)
        clearAllEntitiesFromScene()

        // 3. Build fresh config with the saved WorldMap
        // IMPORTANT: must mirror setupARView config exactly — same flags, same omissions.
        // personSegmentation is intentionally OMITTED: running the segmentation neural
        // network on every frame competes with HandGestureService Vision ML for the ANE →
        // "resource constraints [33]" → world-coordinate drift → entities fly to
        // extreme positions. Disabled for AR tracking stability.
        let config = ARWorldTrackingConfiguration()
        config.environmentTexturing = .none
        config.planeDetection = []
        config.initialWorldMap = wm
        lastConfig = config

        // 4. Run session: resetTracking forces re-localization against the WorldMap.
        //    removeExistingAnchors clears any stale anchors. Entities are recreated
        //    from the flat-file by the post-stabilization restoreMissingBubbles().
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        log.info("🔄 AR session restarted with WorldMap — attendi relocalization (.normal)")
    }

    // MARK: - Edit mode

    func setEditMode(_ on: Bool) {
        isEditMode = on
        // Enable plane detection during edit mode so drag raycasts find surfaces.
        // Disable when leaving edit mode to reduce resource usage.
        setPlaneDetection(on)
        // Suspend Vision ML while plane detection is ON (edit mode) — same ANE contention
        // fix as in beginPlacement. Gesture control is not needed while the user is editing.
        handGestureActive = !on
        guard let arView else { return }

        if on {
            // ── 1-finger pan: surface-snapping translation (delta approach, no initial jump)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleEditPan(_:)))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            arView.addGestureRecognizer(pan)
            editPanGesture = pan

            // ── 2-finger pinch: uniform scale
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleEditPinch(_:)))
            pinch.delegate = self
            arView.addGestureRecognizer(pinch)
            editPinchGesture = pinch

            // ── 2-finger rotation: in-plane Z rotation ("frontalmente")
            let rot = UIRotationGestureRecognizer(target: self, action: #selector(handleEditRotation(_:)))
            rot.delegate = self
            arView.addGestureRecognizer(rot)
            editRotationGesture = rot

        } else {
            // Remove all edit gestures
            [editPanGesture, editPinchGesture, editRotationGesture]
                .compactMap { $0 }
                .forEach { arView.removeGestureRecognizer($0) }
            editPanGesture      = nil
            editPinchGesture    = nil
            editRotationGesture = nil

            // Reset transient drag state
            draggedEntityId    = nil
            dragEntityDepth    = nil
            dragStartEntityPos = nil
            dragStartHitPos    = nil
            scalingEntityId    = nil
            initialScaleForEdit = nil
            rotatingEntityId    = nil
        }
    }

    /// 1-finger drag: moves the element by converting screen-space pixel delta to world-space offset.
    ///
    /// Surface-snapping drag — two-axis decomposition.
    ///
    /// LATERAL (screen X/Y): screen-delta per-frame. Follows the finger exactly.
    ///   Zero jump guaranteed because delta starts at 0.
    ///
    /// DEPTH (camera-forward axis): slow correction toward detected surface, capped at
    ///   4 cm/frame. The element drifts smoothly onto the surface as the finger moves
    ///   it into position; there is no hard teleport.
    ///
    /// Ray-behind filter: if the raycast hit is more than 20 cm FARTHER from the camera
    ///   than the entity, the ray passed through the (non-physical) entity and hit the
    ///   wall behind it. Those hits are discarded — no backward jump.
    @objc private func handleEditPan(_ gesture: UIPanGestureRecognizer) {
        guard let arView, isEditMode else { return }

        // Skip multi-touch (pinch / rotation in progress)
        guard gesture.numberOfTouches <= 1 else {
            draggedEntityId    = nil
            dragEntityDepth    = nil
            dragStartEntityPos = nil
            dragStartHitPos    = nil
            return
        }

        let point = gesture.location(in: arView)

        switch gesture.state {

        case .began:
            draggedEntityId    = nil
            dragEntityDepth    = nil
            dragStartEntityPos = nil
            dragStartHitPos    = nil

            for hit in arView.hitTest(point) {
                let n: String
                if entityMap[hit.entity.name] != nil {
                    n = hit.entity.name
                } else if let pName = hit.entity.parent?.name {
                    // Strip the "anchor_" prefix added by addBubble before looking up entityMap
                    let bareId = pName.hasPrefix("anchor_") ? String(pName.dropFirst(7)) : pName
                    guard entityMap[bareId] != nil else { continue }
                    n = bareId
                } else {
                    continue
                }
                draggedEntityId = n
                if let ae = arView.scene.findEntity(named: "anchor_\(n)") as? AnchorEntity,
                   let frame = arView.session.currentFrame {
                    let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                              frame.camera.transform.columns.3.y,
                                              frame.camera.transform.columns.3.z)
                    let entPos = SIMD3<Float>(ae.transform.matrix.columns.3.x,
                                              ae.transform.matrix.columns.3.y,
                                              ae.transform.matrix.columns.3.z)
                    dragEntityDepth    = max(0.3, simd_length(entPos - camPos))
                    dragStartEntityPos = entPos

                    // Record where the surface is at the exact touch point so we can
                    // compute a grab offset and avoid any jump at the moment of touch.
                    if let q   = arView.makeRaycastQuery(from: point,
                                                         allowing: .estimatedPlane,
                                                         alignment: .any),
                       let hit = arView.session.raycast(q).first {
                        dragStartHitPos = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                                       hit.worldTransform.columns.3.y,
                                                       hit.worldTransform.columns.3.z)
                    } else {
                        // No surface under finger — use the point on the camera ray at entity depth
                        if let q = arView.makeRaycastQuery(from: point,
                                                           allowing: .estimatedPlane,
                                                           alignment: .any) {
                            dragStartHitPos = q.origin + normalize(q.direction) * (dragEntityDepth ?? 1.0)
                        }
                    }
                    log.info("✋ Drag BEGIN \(n) depth=\(String(format:"%.2f", self.dragEntityDepth ?? 0))m")
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                break
            }

        case .changed:
            guard let eid      = draggedEntityId,
                  let ae       = arView.scene.findEntity(named: "anchor_\(eid)") as? AnchorEntity,
                  let startPos = dragStartEntityPos,
                  let startHit = dragStartHitPos,
                  let q        = arView.makeRaycastQuery(from: point,
                                                         allowing: .estimatedPlane,
                                                         alignment: .any)
            else { return }

            // Grab-offset: newElementWorldPos = currentSurfaceHit + grabOffset
            // → element moves by EXACTLY the same delta as the surface point under
            //   the finger. Zero jump at touch-down, smooth across all surfaces.
            let grabOffset = startPos - startHit

            let newPos: SIMD3<Float>
            if let hit = arView.session.raycast(q).first {
                let hitPos = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                          hit.worldTransform.columns.3.y,
                                          hit.worldTransform.columns.3.z)
                newPos = hitPos + grabOffset
                let align = hit.targetAlignment == .vertical ? "parete" : "piano"
                log.debug("✋ MOVE \(eid) → \(align) (\(String(format:"%.2f",newPos.x)),\(String(format:"%.2f",newPos.y)),\(String(format:"%.2f",newPos.z)))")
            } else {
                let depth  = dragEntityDepth ?? 1.0
                let rayPos = q.origin + normalize(q.direction) * depth
                newPos = rayPos + grabOffset
                log.debug("✋ MOVE \(eid) → air (\(String(format:"%.2f",newPos.x)),\(String(format:"%.2f",newPos.y)),\(String(format:"%.2f",newPos.z)))")
            }

            // AnchorEntity(world:) — we own the transform, set it directly.
            var t = simd_float4x4(1)
            t.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)
            ae.transform.matrix = t

        case .ended, .cancelled:
            if let eid = draggedEntityId,
               let ae  = arView.scene.findEntity(named: "anchor_\(eid)") as? AnchorEntity {
                let finalTransform = ae.transform.matrix
                let c3 = finalTransform.columns.3
                log.info("✋ Drag END \(eid) → (\(String(format:"%.2f",c3.x)),\(String(format:"%.2f",c3.y)),\(String(format:"%.2f",c3.z)))")

                // Persist to flat-file immediately — that's the ONLY position store
                // (no ARKit anchors anymore, see architecture note above didAdd).
                ARPersistenceService.shared.updateAnchorTransform(entityId: eid,
                                                                  transform: finalTransform)
            }
            draggedEntityId    = nil
            dragEntityDepth    = nil
            dragStartEntityPos = nil
            dragStartHitPos    = nil

        default: break
        }
    }

    /// 2-finger pinch: uniform scale.
    @objc private func handleEditPinch(_ gesture: UIPinchGestureRecognizer) {
        guard let arView, isEditMode else { return }
        let point = gesture.location(in: arView)

        switch gesture.state {
        case .began:
            scalingEntityId    = nil
            initialScaleForEdit = nil
            for hit in arView.hitTest(point) {
                if let model = entityMap[hit.entity.name] {
                    scalingEntityId     = hit.entity.name
                    initialScaleForEdit = model.scale
                    break
                }
            }
        case .changed:
            guard let eid   = scalingEntityId,
                  let model = entityMap[eid],
                  let init_s = initialScaleForEdit else { return }
            let s = Float(min(max(gesture.scale, 0.25), 4.0))  // clamp 0.25× – 4×
            model.scale = init_s * s
        case .ended, .cancelled:
            // Save scale to persistence so it survives AR session restart
            if let eid = scalingEntityId, let model = entityMap[eid] {
                let rot = userRotations[eid] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                ARPersistenceService.shared.updateModelAppearance(entityId: eid,
                                                                  scale: model.scale,
                                                                  rotation: rot)
            }
            scalingEntityId     = nil
            initialScaleForEdit = nil
        default: break
        }
    }

    /// 2-finger rotation: rotates the bubble in the plane facing the camera (Z axis = "frontalmente").
    /// UIRotationGestureRecognizer.rotation increases clockwise; in a right-hand coordinate system
    /// positive rotation around +Z (toward camera) goes COUNTER-clockwise from the user's POV.
    /// → Negate the angle so clockwise gesture = clockwise result.
    @objc private func handleEditRotation(_ gesture: UIRotationGestureRecognizer) {
        guard let arView, isEditMode else { return }
        let point = gesture.location(in: arView)

        switch gesture.state {
        case .began:
            rotatingEntityId = nil
            for hit in arView.hitTest(point) {
                if entityMap[hit.entity.name] != nil {
                    rotatingEntityId = hit.entity.name
                    break
                }
            }
        case .changed:
            guard let eid   = rotatingEntityId,
                  let model = entityMap[eid] else { return }

            // Negate: UIKit clockwise → positive delta, but simd +Z rotation is CCW → flip
            let delta    = -Float(gesture.rotation)
            let deltaRot = simd_quatf(angle: delta, axis: SIMD3<Float>(0, 0, 1))

            model.orientation = model.orientation * deltaRot

            let prev = userRotations[eid] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            userRotations[eid] = simd_normalize(prev * deltaRot)

            gesture.rotation = 0    // reset incremental delta each frame

        case .ended, .cancelled:
            // Save rotation to persistence so it survives AR session restart
            if let eid = rotatingEntityId, let model = entityMap[eid] {
                ARPersistenceService.shared.updateModelAppearance(entityId: eid,
                                                                  scale: model.scale,
                                                                  rotation: userRotations[eid] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
            }
            rotatingEntityId = nil
        default: break
        }
    }

    // MARK: - Reset user rotations (e.g. if bubble is recreated)

    func resetUserRotation(entityId: String) {
        userRotations.removeValue(forKey: entityId)
    }

    func persistEditedPositions() {
        // NOTE: positions are NOT re-saved here. Every placement writes the flat-file via
        // confirmPlacement → addAnchor, and every drag saves via handleEditPan(.ended) →
        // updateAnchorTransform. Reading ae.transform.matrix at dismissal time can capture
        // a drifted value if ARKit applied a world-frame correction (linearization fallback),
        // overwriting the correct placement position with garbage. Positions stay untouched.
        for (eid, model) in entityMap {
            let rot = userRotations[eid] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            ARPersistenceService.shared.updateModelAppearance(entityId: eid,
                                                              scale: model.scale,
                                                              rotation: rot)
        }
        saveWorldMap()
    }

    // MARK: - Refresh after HA state update

    func refreshBubble(entityId: String) {
        guard let model  = entityMap[entityId],
              let device = HARestService.shared.devices.first(where: { $0.entityId == entityId })
        else { return }
        applyBubbleTexture(for: device, onto: model, alpha: 1.0)
    }

    // MARK: - WorldMap save

    /// Salva la nuvola di feature per la relocalizzazione. ZERO anchor nel file:
    /// le posizioni vivono solo nel flat-file (vedi nota architettura sopra didAdd).
    func saveWorldMap() {
        guard let arView,
              let env = ARPersistenceService.shared.activeEnvironment else { return }
        arView.session.getCurrentWorldMap { wm, _ in
            guard let wm else { return }
            wm.anchors = []
            Task { @MainActor in
                ARPersistenceService.shared.saveWorldMap(wm, for: env)
                log.info("💾 WorldMap salvato (solo nuvola di feature, 0 anchor)")
            }
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ARCoordinator: UIGestureRecognizerDelegate {
    /// Allow pinch and rotation to fire simultaneously (both 2-finger, non-conflicting).
    /// Also prevent pan from conflicting with pinch/rotation when touches > 1.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        let ours: [UIGestureRecognizer?] = [editPanGesture, editPinchGesture, editRotationGesture]
        return ours.contains(gestureRecognizer) && ours.contains(other)
    }
}
