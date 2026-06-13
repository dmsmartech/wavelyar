import Foundation
import Combine
import UIKit

@MainActor
final class HAWebSocketService: ObservableObject {
    static let shared = HAWebSocketService()

    @Published var connectionState: ConnectionState = .disconnected
    @Published var lastStateChange: HAStateChangeEvent?

    private var webSocketTask: URLSessionWebSocketTask?
    private var messageId = 2
    private var reconnectDelay: TimeInterval = 1
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var commandQueue: [Data] = []
    private var isAuthenticated = false
    private let stateChangedSubject = PassthroughSubject<HAStateChangeEvent, Never>()
    private var foregroundObserver: NSObjectProtocol?

    private init() {
        // Reconnect immediately when the app comes back to foreground.
        // After a long background stay iOS tears down the WebSocket and the
        // exponential-backoff reconnect task may be sleeping for up to 60 s.
        // Listening here (inside the service) works regardless of which view
        // is currently on screen.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only reconnect if we were previously connected (not a fresh
                // launch before the user has configured HA).
                guard self.connectionState != .disconnected else { return }
                self.reconnectTask?.cancel()
                self.reconnectDelay = 1          // reset backoff
                self.connect()
            }
        }
    }

    deinit {
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    var stateChangedPublisher: AnyPublisher<HAStateChangeEvent, Never> {
        stateChangedSubject.eraseToAnyPublisher()
    }

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    func connect() {
        guard let config = HAOAuthService.shared.currentConfig,
              let token = HAOAuthService.shared.accessToken else { return }
        connectionState = .connecting
        let url = URL(string: config.wsURL)!
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        isAuthenticated = false
        receiveLoop()
        sendAuth(token: token)
    }

    func disconnect() {
        pingTask?.cancel()
        reconnectTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
    }

    func callService(domain: String, service: String, data: [String: Any]) {
        var payload: [String: Any] = [
            "id": nextMessageId(),
            "type": "call_service",
            "domain": domain,
            "service": service
        ]
        if !data.isEmpty { payload["service_data"] = data }
        send(payload)
    }

    private func sendAuth(token: String) {
        let auth: [String: Any] = ["type": "auth", "access_token": token]
        send(auth)
    }

    private func subscribeEvents() {
        let subscribe: [String: Any] = ["id": 1, "type": "subscribe_events", "event_type": "state_changed"]
        send(subscribe)
    }

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else { return }
        guard connectionState == .connected || connectionState == .connecting else {
            commandQueue.append(data)
            return
        }
        webSocketTask?.send(.string(string)) { [weak self] error in
            if error != nil { Task { @MainActor in self?.scheduleReconnect() } }
        }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                Task { @MainActor in
                    self.handleMessage(message)
                    self.receiveLoop()
                }
            case .failure:
                Task { @MainActor in self.scheduleReconnect() }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "auth_required":
            if let token = HAOAuthService.shared.accessToken { sendAuth(token: token) }
        case "auth_ok":
            isAuthenticated = true
            connectionState = .connected
            reconnectDelay = 1
            subscribeEvents()
            flushCommandQueue()
            startPingPong()
        case "auth_invalid":
            disconnect()
        case "event":
            handleStateChangeEvent(json)
        default:
            break
        }
    }

    private func handleStateChangeEvent(_ json: [String: Any]) {
        guard let eventData = json["event"] as? [String: Any],
              let eventPayload = eventData["data"] as? [String: Any],
              let newState = eventPayload["new_state"] as? [String: Any],
              let entityId = newState["entity_id"] as? String,
              let state = newState["state"] as? String else { return }
        let attributes = newState["attributes"] as? [String: Any] ?? [:]
        let codableAttributes = attributes.compactMapValues { value -> AnyCodable? in
            AnyCodable(value)
        }
        let stateResponse = HAStateResponse(entityId: entityId, state: state,
                                            attributes: codableAttributes, lastChanged: nil)
        let event = HAStateChangeEvent(entityId: entityId, newState: stateResponse)
        lastStateChange = event
        stateChangedSubject.send(event)
        HARestService.shared.updateDevice(from: stateResponse)
    }

    private func flushCommandQueue() {
        let queue = commandQueue
        commandQueue = []
        for data in queue {
            guard let string = String(data: data, encoding: .utf8) else { continue }
            webSocketTask?.send(.string(string)) { _ in }
        }
    }

    private func startPingPong() {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                webSocketTask?.sendPing { [weak self] error in
                    if error != nil { Task { @MainActor in self?.scheduleReconnect() } }
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard connectionState != .disconnected else { return }
        connectionState = .reconnecting
        pingTask?.cancel()
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            reconnectDelay = min(reconnectDelay * 2, 60)
            connect()
        }
    }

    private func nextMessageId() -> Int {
        messageId += 1
        return messageId
    }
}

struct HAStateChangeEvent {
    let entityId: String
    let newState: HAStateResponse
}
