import Foundation
import Vision
import ARKit
import Combine
import os.log

private let log = Logger(subsystem: "WavelyAR", category: "Hand")

@MainActor
final class HandGestureService: ObservableObject {
    static let shared = HandGestureService()

    @Published var detectedGesture: HandGesture?
    @Published var handLandmarks: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
    @Published var auraRadius: CGFloat = 80

    // Buffer for majority-vote stability (3 frames)
    private var gestureBuffer: [HandGesture?] = []
    // Last stable gesture — only emit when state CHANGES (open→closed or closed→open).
    // Exposed as read-only so ARCoordinator can fire immediately for newly-visible devices.
    private(set) var currentStableGesture: HandGesture?

    private let gestureSubject = PassthroughSubject<HandGesture, Never>()
    var gesturePublisher: AnyPublisher<HandGesture, Never> {
        gestureSubject.eraseToAnyPublisher()
    }

    // Serial queue for Vision ML — keeps processing off MainActor so the
    // Task queue in session(_:didUpdate:) never backs up and ARKit can
    // freely reuse ARFrame memory (fixes "retaining 11 ARFrames" warning).
    private let visionQueue = DispatchQueue(label: "com.wavely.ar.vision",
                                            qos: .userInitiated)

    // Skip-if-busy flag — ensures at most ONE pixel buffer is held by visionQueue
    // at any time. When MainActor is briefly blocked (e.g. texture rendering) ARKit
    // delivers multiple frames; without this guard visionQueue would accumulate
    // CVPixelBuffer references that ARKit counts as "retained ARFrames".
    // nonisolated(unsafe): written on visionQueue, read on ARKit's background queue;
    // the occasional torn read just means we process or skip one extra frame — fine.
    private nonisolated(unsafe) var visionProcessing = false

    // MARK: - Process frame

    /// Called from ARKit's background thread (nonisolated).
    /// Immediately dispatches Vision work to visionQueue and returns —
    /// the caller never blocks MainActor with synchronous ML inference.
    /// The `frame: ARFrame` parameter previously here was unused and kept
    /// ARFrames alive inside Task closures; it has been removed.
    nonisolated func processFrame(_ pixelBuffer: CVPixelBuffer, viewportSize: CGSize) {
        // If the previous Vision task is still running, skip this frame.
        // This prevents CVPixelBuffer accumulation in visionQueue when MainActor
        // is temporarily busy (texture rendering, WorldMap save, etc.).
        guard !visionProcessing else { return }
        visionProcessing = true

        visionQueue.async { [weak self] in
            guard let self else { self?.visionProcessing = false; return }
            defer { self.visionProcessing = false }

            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 1
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
            try? handler.perform([request])
            // After perform() the pixel buffer is no longer needed here.
            // ARKit can reclaim the ARFrame once the caller releases its reference.

            guard let obs = request.results?.first else {
                Task { @MainActor [weak self] in
                    self?.handLandmarks   = [:]
                    self?.detectedGesture = nil
                    // DO NOT reset gestureBuffer when hand disappears.
                    // Keeping the buffer intact means that when the hand briefly exits
                    // and re-enters the frame, the existing OPEN/FIST history prevents
                    // the first few uncertain frames from triggering a spurious transition.
                    // The buffer naturally "rotates out" the old data as new observations arrive.
                }
                return
            }

            // Pure computation — safe to run on background queue.
            let landmarks = self.extractLandmarks(obs, viewportSize: viewportSize)
            let aura      = self.computeAuraRadius(obs, viewportSize: viewportSize)
            let gesture   = self.classifyHandState(landmarks: landmarks)

            Task { @MainActor [weak self] in
                self?.handLandmarks = landmarks
                self?.auraRadius    = aura
                self?.updateStateBuffer(gesture)
            }
        }
    }

    // MARK: - Landmark extraction

    // All three helpers below are pure functions (no stored-property access) and
    // are therefore `nonisolated` so visionQueue can call them without actor-hopping.
    private nonisolated func extractLandmarks(_ obs: VNHumanHandPoseObservation,
                                               viewportSize: CGSize) -> [VNHumanHandPoseObservation.JointName: CGPoint] {
        let joints: [VNHumanHandPoseObservation.JointName] = [
            .wrist,
            .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP,   .ringPIP,   .ringDIP,   .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip
        ]
        var result: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
        for joint in joints {
            // Lowered from 0.3 → 0.15 so hands farther from the camera are still detected
            guard let pt = try? obs.recognizedPoint(joint), pt.confidence > 0.15 else { continue }
            result[joint] = CGPoint(x: pt.location.x * viewportSize.width,
                                    y: (1.0 - pt.location.y) * viewportSize.height)
        }
        return result
    }

    // MARK: - Hand state classification
    //
    // Uses NORMALIZED distances: fingertip → palm center, relative to palm size.
    // This works at any hand distance from the camera.
    // Rule: tip closer to palm than 80% of palm size → finger curled.
    // 3+ fingers curled  → closedFist
    // 1 or fewer curled  → openHand
    // Otherwise          → nil (transition, ignored)

    private nonisolated func classifyHandState(landmarks: [VNHumanHandPoseObservation.JointName: CGPoint]) -> HandGesture? {
        guard let wrist     = landmarks[.wrist],
              let palmRef   = landmarks[.middleMCP],  // palm center reference
              let idxTip    = landmarks[.indexTip],
              let midTip    = landmarks[.middleTip],
              let rngTip    = landmarks[.ringTip],
              let litTip    = landmarks[.littleTip]
        else { return nil }

        let palmSize  = dist(wrist, palmRef)
        // Lowered from 10 → 4 px so distant/small hands are still classified
        guard palmSize > 4 else { return nil }  // hand too small / too far

        // Threshold: tip must be closer than 80% of palm size to be "curled"
        let threshold = palmSize * 0.85

        let idxCurled = dist(idxTip, palmRef) < threshold
        let midCurled = dist(midTip, palmRef) < threshold
        let rngCurled = dist(rngTip, palmRef) < threshold
        let litCurled = dist(litTip, palmRef) < threshold

        let curled = [idxCurled, midCurled, rngCurled, litCurled].filter { $0 }.count

        if curled >= 3 { return .closedFist }
        if curled <= 1 { return .openHand }
        return nil  // 2 fingers curled = uncertain transition, skip
    }

    // MARK: - State-change buffer
    //
    // Majority vote over 3 frames → stable gesture.
    // Only fires when the stable gesture CHANGES (e.g. open → closed).
    // This means each state transition fires exactly ONCE, regardless of
    // how long the user holds the gesture.

    private func updateStateBuffer(_ gesture: HandGesture?) {
        gestureBuffer.append(gesture)
        if gestureBuffer.count > 3 { gestureBuffer.removeFirst() }
        guard gestureBuffer.count == 3 else { return }

        let openCount  = gestureBuffer.filter { $0 == .openHand   }.count
        let closeCount = gestureBuffer.filter { $0 == .closedFist }.count

        let stable: HandGesture?
        if openCount  >= 2 { stable = .openHand   }
        else if closeCount >= 2 { stable = .closedFist }
        else                { stable = nil }

        guard let s = stable else { return }

        // Emit ONLY when state changes
        if s != currentStableGesture {
            log.info("🖐 Stable gesture changed: \(self.currentStableGesture.map { $0 == .openHand ? "OPEN" : "FIST" } ?? "nil") → \(s == .openHand ? "OPEN" : "FIST")")
            currentStableGesture = s
            detectedGesture   = s
            gestureSubject.send(s)
        }
    }

    // MARK: - Aura radius

    private nonisolated func computeAuraRadius(_ obs: VNHumanHandPoseObservation,
                                               viewportSize: CGSize) -> CGFloat {
        guard let w  = try? obs.recognizedPoint(.wrist),
              let m  = try? obs.recognizedPoint(.middleMCP),
              w.confidence > 0.4, m.confidence > 0.4 else { return 80 }
        let d = dist(CGPoint(x: w.location.x, y: w.location.y),
                     CGPoint(x: m.location.x, y: m.location.y))
        return max(60, min(200, d * viewportSize.height * 2.5))
    }

    private nonisolated func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
