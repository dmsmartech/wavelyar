import SwiftUI
import Vision

struct AuraOverlay: View {
    @ObservedObject private var handService = HandGestureService.shared

    var body: some View {
        Canvas { context, _ in
            guard let wristPoint = handService.handLandmarks[.wrist],
                  let middleMCPPoint = handService.handLandmarks[.middleMCP] else { return }

            let palmCenter = CGPoint(
                x: (wristPoint.x + middleMCPPoint.x) / 2,
                y: (wristPoint.y + middleMCPPoint.y) / 2
            )
            let radius = handService.auraRadius

            let rect = CGRect(x: palmCenter.x - radius, y: palmCenter.y - radius,
                              width: radius * 2, height: radius * 2)

            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.25)), lineWidth: 1.5)

            let innerRect = CGRect(x: palmCenter.x - radius * 0.3, y: palmCenter.y - radius * 0.3,
                                   width: radius * 0.6, height: radius * 0.6)
            context.fill(Path(ellipseIn: innerRect), with: .color(.white.opacity(0.08)))
        }
        .allowsHitTesting(false)
    }
}
