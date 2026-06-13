import SwiftUI

struct SplashView: View {
    @State private var scale: CGFloat = 0.7
    @State private var opacity: Double = 0
    @State private var glowOpacity: Double = 0

    let onComplete: () -> Void

    var body: some View {
        ZStack {
            Color("Background").ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color("AccentStart").opacity(0.4), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .opacity(glowOpacity)
                .blur(radius: 40)

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color("AccentStart"), Color("AccentEnd")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)
                        .shadow(color: Color("AccentStart").opacity(0.5), radius: 30)

                    Image(systemName: "hand.wave.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                }

                VStack(spacing: 6) {
                    Text("Wavely AR")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Controlla la tua casa in realtà aumentata")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) {
                scale = 1
                opacity = 1
            }
            withAnimation(.easeIn(duration: 0.8).delay(0.3)) {
                glowOpacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                onComplete()
            }
        }
    }
}
