import SwiftUI
import Vision

struct LaserRayOverlay: View {
    @ObservedObject private var handService = HandGestureService.shared
    @State private var pulse = false

    var body: some View {
        Canvas { context, size in
            guard handService.detectedGesture == .indexPointing,
                  let indexTip = handService.handLandmarks[.indexTip],
                  let indexDIP = handService.handLandmarks[.indexDIP] else { return }

            let direction = CGPoint(x: indexTip.x - indexDIP.x, y: indexTip.y - indexDIP.y)
            let length = sqrt(direction.x * direction.x + direction.y * direction.y)
            guard length > 0 else { return }

            let normalized = CGPoint(x: direction.x / length, y: direction.y / length)
            let rayLength: CGFloat = 300
            let endPoint = CGPoint(x: indexTip.x + normalized.x * rayLength,
                                   y: indexTip.y + normalized.y * rayLength)

            var path = Path()
            path.move(to: indexTip)
            path.addLine(to: endPoint)

            let gradient = Gradient(colors: [
                Color("AccentStart").opacity(pulse ? 0.9 : 0.6),
                Color("AccentEnd").opacity(0)
            ])
            context.stroke(path, with: .linearGradient(gradient,
                                                        startPoint: indexTip,
                                                        endPoint: endPoint), lineWidth: 2)

            let tipRect = CGRect(x: indexTip.x - 4, y: indexTip.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: tipRect), with: .color(Color("AccentStart").opacity(0.8)))
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
