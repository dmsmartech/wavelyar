import SwiftUI
import Vision

struct HandSkeletonOverlay: View {
    @ObservedObject private var handService = HandGestureService.shared

    private let connections: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP)
    ]

    var body: some View {
        Canvas { ctx, _ in
            let landmarks = handService.handLandmarks
            guard !landmarks.isEmpty else { return }

            // ── Shadow pass (gives glow/depth so skeleton pops over white bubbles)
            for (from, to) in connections {
                guard let p1 = landmarks[from], let p2 = landmarks[to] else { continue }
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                ctx.stroke(path,
                           with: .color(Color("AccentStart").opacity(0.45)),
                           style: StrokeStyle(lineWidth: 7, lineCap: .round))
            }

            // ── Main skeleton lines
            for (from, to) in connections {
                guard let p1 = landmarks[from], let p2 = landmarks[to] else { continue }
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                ctx.stroke(path,
                           with: .color(.white.opacity(0.92)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            // ── Joints: outer ring (accent) + inner fill (white)
            for point in landmarks.values {
                // Accent glow ring
                let ring = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
                ctx.fill(Path(ellipseIn: ring), with: .color(Color("AccentStart").opacity(0.5)))

                // White core
                let core = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: core), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }
}
