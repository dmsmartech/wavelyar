import SwiftUI

/// Rendered via ImageRenderer as a texture on a RealityKit plane.
/// Must use solid colors only (no materials, no ultraThinMaterial).
/// Size: 300×160 pt — matches mesh ratio 0.24m × 0.128m exactly.
struct DeviceBubbleSnapshot: View {
    let device: HADevice

    // MARK: - Layout constants (match mesh aspect ratio 300:160)
    static let renderWidth:  CGFloat = 300
    static let renderHeight: CGFloat = 160

    var body: some View {
        ZStack {
            // ── Base card
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white)

            // ── Subtle inner shadow simulation (top highlight)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(white: 0.96)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // ── Content
            HStack(spacing: 14) {
                iconView
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.friendlyName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(Color(white: 0.1))
                        .lineLimit(1)
                    primaryValueView
                }
                Spacer(minLength: 0)
                stateIndicator
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        // ── Thin colored border based on state
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1.5)
        )
        .frame(width: Self.renderWidth, height: Self.renderHeight)
    }

    // MARK: - Icon

    private var iconView: some View {
        ZStack {
            Circle()
                .fill(iconBackground)
                .frame(width: 44, height: 44)
            Image(systemName: iconSystemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(iconForeground)
        }
    }

    // MARK: - Primary value

    @ViewBuilder
    private var primaryValueView: some View {
        switch device.domain {
        case .light:
            if device.isOn, let b = device.attributes["brightness"]?.doubleValue {
                Text("\(Int((b / 255) * 100))%")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(Color(white: 0.15))
            } else {
                Text(device.isOn ? "Accesa" : "Spenta")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(Color(white: 0.45))
            }

        case .switch:
            if let w = device.attributes["current_power"]?.doubleValue {
                Text("\(Int(w)) W")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(Color(white: 0.15))
            } else {
                Text(device.isOn ? "Acceso" : "Spento")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(Color(white: 0.45))
            }

        case .climate:
            if let cur = device.attributes["current_temperature"]?.doubleValue,
               let tgt = device.attributes["temperature"]?.doubleValue {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(cur))°C")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(Color(white: 0.15))
                    Text("→ \(Int(tgt))°C")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(Color(white: 0.5))
                }
            }

        case .sensor:
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(device.state)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(Color(white: 0.15))
                if let unit = device.attributes["unit_of_measurement"]?.stringValue {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(Color(white: 0.5))
                }
            }

        case .lock:
            Text(device.state == "locked" ? "Chiusa" : "Aperta")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(device.state == "locked" ? .green : .red)

        default:
            Text(device.stateLabel)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(Color(white: 0.45))
        }
    }

    // MARK: - State indicator (right side)

    @ViewBuilder
    private var stateIndicator: some View {
        if device.domain == .light || device.domain == .switch {
            Capsule()
                .fill(device.isOn ? onColor : Color(white: 0.88))
                .frame(width: 10, height: 28)
        } else if device.domain == .sensor || device.domain == .binary_sensor {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(white: 0.6))
        }
    }

    // MARK: - Colors

    private var onColor: Color {
        switch device.domain {
        case .light:  return device.lightColor
        case .switch: return .green
        default:      return Color(red: 0.114, green: 0.518, blue: 0.894)
        }
    }

    private var borderColor: Color {
        if device.isUnavailable { return Color(white: 0.88) }
        return device.isOn ? onColor.opacity(0.5) : Color(white: 0.88)
    }

    private var iconBackground: Color {
        if device.isUnavailable { return Color(white: 0.93) }
        if device.isOn          { return onColor.opacity(0.12) }
        return Color(white: 0.93)
    }

    private var iconForeground: Color {
        if device.isUnavailable { return Color(white: 0.65) }
        if device.isOn          { return onColor }
        return Color(white: 0.55)
    }

    private var iconSystemName: String {
        switch device.domain {
        case .light:         return device.isOn ? "lightbulb.fill" : "lightbulb"
        case .switch:        return device.isOn ? "powerplug.fill" : "powerplug"
        case .climate:       return "thermometer.medium"
        case .lock:          return device.state == "locked" ? "lock.fill" : "lock.open.fill"
        case .camera:        return "camera.fill"
        case .sensor:        return "sensor.tag.radiowaves.forward.fill"
        case .binary_sensor: return binarySensorIcon
        case .unknown:       return "questionmark.circle"
        }
    }

    private var binarySensorIcon: String {
        switch device.attributes["device_class"]?.stringValue {
        case "door":   return "door.left.hand.open"
        case "window": return "window.vertical.open"
        case "motion": return "figure.walk"
        case "smoke":  return "smoke.fill"
        default:       return "sensor.tag.radiowaves.forward.fill"
        }
    }
}
