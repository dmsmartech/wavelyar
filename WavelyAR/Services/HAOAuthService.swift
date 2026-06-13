import Foundation
import AuthenticationServices
import Security

@MainActor
final class HAOAuthService: ObservableObject {
    static let shared = HAOAuthService()
    private let presentationProvider = OAuthPresentationProvider()

    @Published var isAuthenticated = false
    @Published var isAuthenticating = false
    @Published var error: String?

    private var config: HAConfig?
    private let keychainAccessToken = "wavely.ha.access_token"
    private let keychainRefreshToken = "wavely.ha.refresh_token"
    private let keychainConfig = "wavely.ha.config"
    private let clientId = "https://home-assistant.io/ios"
    private let redirectURI = "homeassistant://auth-callback"
    private var authSession: ASWebAuthenticationSession?

    init() {
        loadSavedConfig()
    }

    var accessToken: String? { loadFromKeychain(key: keychainAccessToken) }
    var currentConfig: HAConfig? { config }

    func configure(with haConfig: HAConfig) {
        config = haConfig
        saveConfigToKeychain(haConfig)
    }

    func startOAuthFlow() async throws {
        guard let config else { throw HAOAuthError.notConfigured }
        isAuthenticating = true
        defer { isAuthenticating = false }

        var components = URLComponents(string: "\(config.baseURL)/auth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code")
        ]
        let authURL = components.url!

        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "homeassistant") { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url = callbackURL,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: HAOAuthError.invalidCallback)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self.presentationProvider
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }

        try await exchangeCodeForTokens(code: code)
        isAuthenticated = true
    }

    func refreshAccessTokenIfNeeded() async throws {
        guard let refreshToken = loadFromKeychain(key: keychainRefreshToken),
              let config else { throw HAOAuthError.notConfigured }

        
        var request = URLRequest(url: URL(string: "\(config.baseURL)/auth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(clientId)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let tokenResponse = try JSONDecoder().decode(HATokenResponse.self, from: data)
        saveToKeychain(key: keychainAccessToken, value: tokenResponse.accessToken)
        if let newRefresh = tokenResponse.refreshToken {
            saveToKeychain(key: keychainRefreshToken, value: newRefresh)
        }
    }

    func logout() {
        deleteFromKeychain(key: keychainAccessToken)
        deleteFromKeychain(key: keychainRefreshToken)
        deleteFromKeychain(key: keychainConfig)
        config = nil
        isAuthenticated = false
    }


    private func exchangeCodeForTokens(code: String) async throws {
        guard let config else { throw HAOAuthError.notConfigured }
        
        var request = URLRequest(url: URL(string: "\(config.baseURL)/auth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=authorization_code&code=\(code)&redirect_uri=\(redirectURI)&client_id=\(clientId)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let tokenResponse = try JSONDecoder().decode(HATokenResponse.self, from: data)
        saveToKeychain(key: keychainAccessToken, value: tokenResponse.accessToken)
        if let refreshToken = tokenResponse.refreshToken {
            saveToKeychain(key: keychainRefreshToken, value: refreshToken)
        }
    }

    private func loadSavedConfig() {
        guard let data = loadDataFromKeychain(key: keychainConfig),
              let savedConfig = try? JSONDecoder().decode(HAConfig.self, from: data) else { return }
        config = savedConfig
        isAuthenticated = loadFromKeychain(key: keychainAccessToken) != nil
    }

    private func saveConfigToKeychain(_ config: HAConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        saveDataToKeychain(key: keychainConfig, data: data)
    }

    private func saveToKeychain(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        saveDataToKeychain(key: key, data: data)
    }

    private func saveDataToKeychain(key: String, data: Data) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrAccount as String: key,
                                         kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        guard let data = loadDataFromKeychain(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func loadDataFromKeychain(key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

private struct HATokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

enum HAOAuthError: Error, LocalizedError {
    case notConfigured
    case invalidCallback
    case tokenExchangeFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Home Assistant non configurato"
        case .invalidCallback: return "Callback OAuth non valido"
        case .tokenExchangeFailed: return "Scambio token fallito"
        }
    }
}

// NSObject isolated separately — avoids @MainActor+NSObject ObjC runtime crash
final class OAuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIWindow()
    }
}
