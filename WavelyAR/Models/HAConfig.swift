import Foundation
import Combine

enum AppScreen { case splash, discovery, main }

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var screen: AppScreen = .splash

    init() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if HAOAuthService.shared.isAuthenticated {
                HAWebSocketService.shared.connect()
                Task { await HARestService.shared.fetchAllDevices() }
                self.screen = .main
            } else {
                self.screen = .discovery
            }
        }
    }

    func completeSplash() {
        if HAOAuthService.shared.isAuthenticated {
            HAWebSocketService.shared.connect()
            Task { await HARestService.shared.fetchAllDevices() }
            screen = .main
        } else {
            screen = .discovery
        }
    }

    func goToMain() {
        HAWebSocketService.shared.connect()
        Task { await HARestService.shared.fetchAllDevices() }
        screen = .main
    }

    func goToDiscovery() { screen = .discovery }
}

struct HAConfig: Codable {
    var host: String
    var port: Int
    var useTLS: Bool

    var baseURL: String {
        let scheme = useTLS ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
    }

    var wsURL: String {
        let scheme = useTLS ? "wss" : "ws"
        return "\(scheme)://\(host):\(port)/api/websocket"
    }
}

struct HADiscoveredInstance: Identifiable {
    let id = UUID()
    let name: String
    let host: String
    let port: Int
    let useTLS: Bool

    var displayAddress: String { "\(host):\(port)" }

    func toConfig() -> HAConfig {
        HAConfig(host: host, port: port, useTLS: useTLS)
    }
}

enum HandGesture {
    case openHand
    case closedFist
    case indexPointing
}
