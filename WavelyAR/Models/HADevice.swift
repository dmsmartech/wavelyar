import Foundation
import SwiftUI

enum HADomain: String, CaseIterable {
    case light
    case `switch`
    case climate
    case lock
    case camera
    case binary_sensor
    case sensor
    case unknown

    var displayName: String {
        switch self {
        case .light: return "Luci"
        case .switch: return "Prese/Switch"
        case .climate: return "Termostati"
        case .lock: return "Serrature"
        case .camera: return "Videocamere"
        case .binary_sensor: return "Sensori"
        case .sensor: return "Sensori generici"
        case .unknown: return "Altro"
        }
    }

    var icon: String {
        switch self {
        case .light: return "lightbulb.fill"
        case .switch: return "powerplug.fill"
        case .climate: return "thermometer"
        case .lock: return "lock.fill"
        case .camera: return "camera.fill"
        case .binary_sensor: return "sensor.tag.radiowaves.forward.fill"
        case .sensor: return "chart.bar.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct HADevice: Identifiable, Hashable {
    let id: String
    var entityId: String
    var friendlyName: String
    var state: String
    var attributes: [String: AnyCodable]
    var domain: HADomain
    var lastChanged: Date?

    var isOn: Bool { state == "on" || state == "locked" || state == "closed" }
    var isUnavailable: Bool { state == "unavailable" || state == "unknown" }

    var statusColor: Color {
        if isUnavailable { return Color.white.opacity(0.2) }
        if domain == .lock { return state == "locked" ? .green : .red }
        return isOn ? .green : .gray
    }

    /// Warm colour derived from HA color_temp / rgb_color attributes (for lights)
    var lightColor: Color {
        if let rgb = attributes["rgb_color"]?.value as? [AnyCodable], rgb.count == 3,
           let r = rgb[0].doubleValue, let g = rgb[1].doubleValue, let b = rgb[2].doubleValue {
            return Color(red: r / 255, green: g / 255, blue: b / 255)
        }
        if let ct = attributes["color_temp"]?.doubleValue {
            // Map mireds (153–500) → warm white (yellow) to cool white (blue-white)
            let t = max(0, min(1, (ct - 153) / 347))
            return Color(red: 1.0, green: 0.85 + (0.15 * (1 - t)), blue: 0.5 + (0.5 * (1 - t)))
        }
        return Color.yellow.opacity(0.85)
    }


    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: HADevice, rhs: HADevice) -> Bool { lhs.id == rhs.id }
}

struct AnyCodable: Codable, Hashable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyCodable].self) { value = array }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [AnyCodable]: try container.encode(array)
        case let dict as [String: AnyCodable]: try container.encode(dict)
        default: try container.encodeNil()
        }
    }

    func hash(into hasher: inout Hasher) {
        if let string = value as? String { hasher.combine(string) }
        else if let int = value as? Int { hasher.combine(int) }
        else if let double = value as? Double { hasher.combine(double) }
        else if let bool = value as? Bool { hasher.combine(bool) }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (let l as String, let r as String): return l == r
        case (let l as Int, let r as Int): return l == r
        case (let l as Double, let r as Double): return l == r
        case (let l as Bool, let r as Bool): return l == r
        default: return false
        }
    }

    var stringValue: String? { value as? String }
    var doubleValue: Double? { value as? Double }
    var intValue: Int? { value as? Int }
    var boolValue: Bool? { value as? Bool }
}

struct HAStateResponse: Codable {
    let entityId: String
    let state: String
    let attributes: [String: AnyCodable]
    let lastChanged: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case state
        case attributes
        case lastChanged = "last_changed"
    }

    func toDevice() -> HADevice {
        let parts = entityId.split(separator: ".")
        let domainString = parts.first.map(String.init) ?? ""
        let domain = HADomain(rawValue: domainString) ?? .unknown
        let friendlyName = attributes["friendly_name"]?.stringValue ?? entityId
        var lastChangedDate: Date?
        if let dateString = lastChanged {
            let formatter = ISO8601DateFormatter()
            lastChangedDate = formatter.date(from: dateString)
        }
        return HADevice(
            id: entityId,
            entityId: entityId,
            friendlyName: friendlyName,
            state: state,
            attributes: attributes,
            domain: domain,
            lastChanged: lastChangedDate
        )
    }
}
