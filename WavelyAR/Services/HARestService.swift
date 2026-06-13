import Foundation
import Combine

@MainActor
final class HARestService: ObservableObject {
    static let shared = HARestService()

    @Published var devices: [HADevice] = []
    @Published var isLoading = false
    @Published var error: String?

    private var config: HAConfig? { HAOAuthService.shared.currentConfig }
    private var accessToken: String? { HAOAuthService.shared.accessToken }

    func fetchAllDevices() async {
        isLoading = true
        error = nil
        do {
            let states = try await request([HAStateResponse].self, path: "/api/states")
            devices = states
                .map { $0.toDevice() }
                .filter { $0.domain != .unknown }
                .sorted { $0.friendlyName < $1.friendlyName }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
        // After devices load, restore any AR bubbles that couldn't be rendered at session start
        ARCoordinator.shared.restoreMissingBubbles()
    }

    func fetchHistory(entityId: String, hoursBack: Int = 24) async throws -> [[HAHistoryState]] {
        let formatter = ISO8601DateFormatter()
        let startTime = formatter.string(from: Date().addingTimeInterval(-Double(hoursBack) * 3600))
        return try await request([[HAHistoryState]].self, path: "/api/history/period/\(startTime)?filter_entity_id=\(entityId)&minimal_response=true")
    }

    func fetchCameraProxy(entityId: String) async throws -> Data {
        return try await rawRequest(path: "/api/camera_proxy/\(entityId)")
    }

    func updateDevice(from state: HAStateResponse) {
        let updated = state.toDevice()
        if let idx = devices.firstIndex(where: { $0.entityId == updated.entityId }) {
            devices[idx] = updated
        } else {
            devices.append(updated)
        }
    }

    private func request<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let data = try await rawRequest(path: path)
        return try JSONDecoder().decode(type, from: data)
    }

    private func rawRequest(path: String) async throws -> Data {
        guard let config, let token = accessToken else { throw HARestError.notAuthenticated }
        guard let url = URL(string: "\(config.baseURL)\(path)") else { throw HARestError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                try await HAOAuthService.shared.refreshAccessTokenIfNeeded()
                var retryRequest = URLRequest(url: url, timeoutInterval: 5)
                retryRequest.setValue("Bearer \(HAOAuthService.shared.accessToken ?? "")", forHTTPHeaderField: "Authorization")
                let (retryData, _) = try await URLSession.shared.data(for: retryRequest)
                return retryData
            }
            return data
        } catch {
            throw HARestError.networkError(error)
        }
    }
}

struct HAHistoryState: Codable {
    let entityId: String?
    let state: String?
    let lastChanged: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case state
        case lastChanged = "last_changed"
    }
}

enum HARestError: Error, LocalizedError {
    case notAuthenticated
    case invalidURL
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Non autenticato"
        case .invalidURL: return "URL non valido"
        case .networkError(let e): return e.localizedDescription
        }
    }
}
