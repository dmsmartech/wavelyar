import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UIWindow.appearance().backgroundColor = UIColor(named: "Background") ?? .black
        return true
    }
}

@main
struct WavelyARApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        ZStack {
            Color("Background").ignoresSafeArea()

            switch appState.screen {
            case .splash:
                SplashView { appState.completeSplash() }
                    .transition(.opacity)
            case .discovery:
                DiscoveryView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
            case .main:
                MainListView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: appState.screen)
    }
}
